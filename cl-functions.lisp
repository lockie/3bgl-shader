(in-package #:3bgl-shaders)
;;; add some builtin functions for testing
;;; todo: move these somewhere separate and add missing functions


;; we have 3 general styles of internal function/operators
;; simple case: all args are same type or concrete type
;;   ex: =, fma
;; slightly harder cases: most args same type or concrete
;;   except some are same size from different category
;;     ex: lessThan
;;   or same type or scalar of same type
;;     ex: +, clamp, smoothstep
;; general case: just list all possibly combinations by hand
;;     ex: *, textureSize
(defun add-internal-function/s (name lambda-list arg-types return-type &key glsl-name (cast t))
  (let ((fn (make-instance 'internal-function
                           :name name
                           :glsl-name glsl-name
                           :lambda-list lambda-list))
        (types (make-array (count '&optional lambda-list :test-not #'eql)
                           :initial-element nil)))
    ;; ignoring (out ..) on types for now, but allowed so they can be
    ;; added to signatures in case they are useful later...
    (setf arg-types
          (mapcar (lambda (x) (if (typep x '(cons (eql :out))) (second x) x))
                  arg-types))
    ;; 2 passes, so types can be constrained by later args
    ;; (ex smoothstep, first 2 args are constrained by 3rd)
    (setf (bindings fn)
          (loop with optional = nil
                with arg-type = nil
                with i = 0
                for variable-name in lambda-list
                when (eq variable-name '&optional)
                  do (setf optional t)
                else
                  do (setf arg-type (pop arg-types))
                     (typecase arg-type
                       ;; (or ...) list of types
                       ((cons (eql or))
                        (setf (aref types i)
                              ;; no constraints, since we only have
                              ;; equality constraints here, which are
                              ;; just represented with same type
                              ;; object
                              (make-instance
                               'constrained-type
                               :types (alexandria:alist-hash-table
                                       (mapcar (lambda (a)
                                                 (cons (or (get-type-binding a)
                                                           a)
                                                       t))
                                               (cdr arg-type))))))
                       ((eql t)
                        (setf (aref types i)
                              (make-instance 'any-type)))
                       (symbol
                        (setf (aref types i)
                              (or (get-type-binding arg-type)
                                  (error "unknown type ~s?" arg-type)))))
                  and collect (make-instance
                               'binding
                               :name variable-name
                               :value-type (if optional
                                               (make-instance
                                                'optional-arg-type
                                                :arg-type (or (aref types i)
                                                              arg-type))
                                               (or (aref types i)
                                                   arg-type))
                               :allow-casts cast)
                  and do (incf i)))

    (loop for binding in (bindings fn)
          for value-type = (value-type binding)
          for arg-type = (if (typep value-type 'optional-arg-type)
                             (arg-type value-type)
                             value-type)
          for i from 0
          when (consp arg-type)
            do (flet ((update-type (i new)
                        (if (typep value-type 'optional-arg-type)
                            (setf (arg-type value-type) new
                                  (aref types i) value-type)
                            (setf (aref types i) new
                                  (value-type binding) new))))
                 (etypecase arg-type
                   ;; (= ##) same types as arg ##
                   ((cons (eql =))
                    (update-type i (aref types (second arg-type))))
                   ;; (s ##) scalar base type of arg ##
                   ((cons (eql s))
                    (let ((c (make-instance
                              'scalar-type-of-constraint
                              :ctype (update-type
                                      i
                                      ;; fixme: limit this based on other-type
                                      (make-instance 'any-type))
                              :other-type (aref types (second arg-type)))))
                      (add-constraint (aref types (second arg-type)) c)
                      (add-constraint (ctype c) c)))
                   ;; (=s ##) same type as or scalar base type of arg ##
                   ((cons (eql =s))
                    (let ((c (make-instance
                              'same-type-or-scalar-constraint
                              :ctype (update-type
                                      i
                                      ;; fixme: limit this based on other-type
                                      (make-instance 'any-type))
                              :other-type (aref types (second arg-type)))))
                      (add-constraint (aref types (second arg-type)) c)
                      (add-constraint (ctype c) c)))
                   ;; (=# ## base-type) same element count as arg ## but
                   ;; specified base type (ex :bool => vec3 -> bvec3)
                   ((cons (eql =#))
                    (let ((c (make-instance
                              'same-size-different-base-type-constraint
                              :other-type (aref types (second arg-type))
                              :base-type (get-type-binding (third arg-type))
                              :ctype (update-type
                                      i (make-instance 'any-type)))))
                      (add-constraint (aref types (second arg-type)) c)
                      (add-constraint (ctype c) c))))))
    (etypecase return-type
      ;; (OR) types not allowed for return type, has to either match
      ;; an arg type or be a specific type
      ((cons (eql s))
       (let ((c (make-instance
                 'scalar-type-of-constraint
                 :ctype (setf (value-type fn)
                              ;; fixme: limit this based on other-type
                              (make-instance 'any-type))
                 :other-type (aref types (second return-type)))))
         (add-constraint (aref types (second return-type)) c)
         (add-constraint (value-type fn) c)))
      ((cons (eql =#))
       (let ((c (make-instance 'same-size-different-base-type-constraint
                               :ctype (setf (value-type fn)
                                            (make-instance 'any-type))
                               :other-type (aref types (second return-type))
                               :base-type (get-type-binding
                                           (third return-type)))))
         (add-constraint (aref types (second return-type)) c)
         (add-constraint (value-type fn) c)))
      ((cons (eql =))
       (when *verbose*
         (format t "~&setting return type of ~s to ~s~%"
                 (name fn)
                 (aref types (second return-type))))
       (setf (value-type fn) (aref types (second return-type))))
      ((eql t)
       (setf (value-type fn) (make-instance 'any-type)))
      (symbol
       (setf (value-type fn) (get-type-binding return-type))))
    (setf (gethash name (function-bindings *environment*))
          fn)))

(defun add-internal-function/mat (name lambda-list count return-type
                                  &key glsl-name)
  ;; matrix constructors types are too complex to enumerate explicitly
  ;; (nearly 3 million for mat3), so we need to use a special
  ;; constraint for them
  ;; (may just accept 1-COUNT of ARG-TYPES for now, eventually should
  ;;  enforce that it is passed either 1 matrix type or a combination
  ;;  of arg-types that adds up to exactly COUNT elements)
  ;; for now just enumerating the combinations of sizes, and handling
  ;;  them like implicit casts except allowing cast to any same-size
  ;;  type still a bit big (24k for mat4, 5.2k at worst arity for
  ;;  mat4), but relatively manageable
  ;; fixme: test performance of stuff with lots of calls to mat4
  (let* ((fn (make-instance 'internal-function
                            :name name
                            :glsl-name glsl-name
                            :lambda-list lambda-list
                            ;; :declared-type ?
                            :value-type (get-type-binding return-type)))
         (arity-types (make-array (1+ count) :initial-element nil))
         (arg-types (make-array (1+ count) :initial-element nil))
         (constraint (make-instance
                      'variable-arity-function-application
                      :name name
                      :return-type (get-type-binding return-type)
                      :function-types-by-arity arity-types))
         (base-types '((:float 1) (:vec2 2) (:vec3 3) (:vec4 4)
                       (:mat2 4) (:mat2x3 6) (:mat2x4 8)
                       (:mat3x2 6) (:mat3 9) (:mat3x4 12)
                       (:mat4x2 8) (:mat4x3 12) (:mat4 16))))
    ;; accept any of the base types (or anything that casts to them)
    ;; for 1ary function
    (setf (aref arity-types 1)
          (mapcar (lambda (a) (list (list (car a)) return-type))
                  base-types))

    ;; accept any combination of args that adds up to COUNT elements
    ;; for n-ary functions where (<= 2 N COUNT)
    (labels ((vec/mat-constructor (n)
               (if (zerop n)
                   (list nil)
                   (loop for (type count) in base-types
                         when (<= count n)
                           append (mapcar (lambda (a) (cons type a))
                                          (vec/mat-constructor (- n count)))))))
      (loop for type in (vec/mat-constructor count)
            for l = (length type)
            when (> l 1)
              do (push (list type return-type)
                       (aref arity-types l))))

    ;; figure out which types are valid for specific args
    ;; (for example last type is always nil/scalar only)
    ;; fixme: probably should calculate this directly
    (loop for i from 1 to count
          for ftypes = (aref arity-types i)
          do (loop for ftype in ftypes
                   do (loop for j below i
                            do (pushnew (nth j (car ftype))
                                        (aref arg-types j)))))
    #++(break "foo" (list arity-types arg-types))
    ;; update arg types in constraint
    (setf (argument-types constraint)
          (loop for i below count
                for arg-type across arg-types
                for ct = (make-instance
                          'constrained-type
                          :types (alexandria:alist-hash-table
                                  (mapcar (lambda (a)
                                            (cons (or (get-type-binding a)
                                                      a)
                                                  t))
                                          arg-type))
                          :constraints (alexandria:plist-hash-table
                                        (list constraint t)))
                collect (if (plusp i)
                            (make-instance 'optional-arg-type
                                           :arg-type ct)
                            ct)))
    ;; and bindings in fn
    (setf (bindings fn)
          (loop with types = (argument-types constraint)
                with i = 0
                for binding in lambda-list
                unless (eq binding '&optional)
                  collect (make-instance 'binding
                                         :name binding
                                         :value-type (pop types)
                                         :allow-casts :explicit)
                  and do (incf i)))
    ;; and add function binding
    (setf (gethash name (function-bindings *environment*))
          fn)))

(defun add-internal-function/full (name lambda-list type &key glsl-name (cast t))
  (let* ((fn (make-instance 'internal-function
                            :name name
                            :glsl-name glsl-name
                            :lambda-list lambda-list
                            :declared-type type))
         (arity-types (make-array (1+ (length (remove '&optional lambda-list)))
                                  :initial-element nil))
         (constraint (make-instance
                      'variable-arity-function-application
                      :name name
                      :function-types-by-arity arity-types))
         (ret-types (mapcar (lambda (a) (cons (get-type-binding a) t))
                            (delete-duplicates
                             (mapcar 'second type))))
         (ret (if (<= (length ret-types) 1)
                  (caar ret-types)
                  (make-instance 'constrained-type
                                 :types (alexandria:alist-hash-table
                                         ret-types)
                                 :constraints (alexandria:plist-hash-table
                                               (list constraint t))))))

    (loop for ftype in type
          for l = (length (first ftype))
          minimizing l into min
          maximizing l into max
          do (push ftype (aref arity-types l))
          finally (setf (min-arity constraint) min
                        (max-arity constraint) max))

    (when (= (min-arity constraint) (max-arity constraint))
      (change-class constraint 'function-application
                    :function-types type))

    (setf (return-type constraint) ret
          (value-type fn) ret)

    ;; allowing &optional in lambda list, no other l-l-keywords though
    ;; just plain symbols for optional args, no default or -p arg
    (flet ((make-type (n)
             (let* ((types (delete-duplicates
                            (mapcar (lambda (a)
                                      (nth n (car a)))
                                    type)))
                    (type (make-instance 'constrained-type
                                         :types
                                         (alexandria:alist-hash-table
                                          (mapcar (lambda (a)
                                                    (cons (or (get-type-binding a)
                                                              a
                                                              nil)
                                                          t))
                                                  (remove nil types)))
                                         :constraints
                                         (alexandria:plist-hash-table
                                          (list constraint t)))))
               (when (position nil types)
                 (setf type (make-instance 'optional-arg-type
                                           :arg-type type)))
               (push type (argument-types constraint))
               type)))
      (setf (bindings fn)
            (loop with optional = nil
                  with i = 0
                  for binding in lambda-list
                  when (eq binding '&optional)
                    do (setf optional t)
                  else
                    collect (make-instance 'binding
                                           :name binding
                                           :value-type (make-type i)
                                           :allow-casts cast)
                    and do (incf i))))
    (setf (argument-types constraint) (reverse (argument-types constraint)))

    (setf (gethash name (function-bindings *environment*))
          fn)))

;; fixme: use expand-signatures instead of make-ftype more places
(labels ((make-ftype (ret &rest args)
           (unless (consp ret)
             (setf ret (make-list (length args) :initial-element ret)))
           ;; fixme: remove duplicate entries
           (apply #'mapcar
                  (lambda (r &rest a)
                    (list a r))
                  ret args))
         (ensure-list* (x length)
           (if (consp x)
               x
               (make-list length :initial-element x)))
         (expand-signature (ret args &key req)
           ;; ret args are either keywords or lists of keywords
           ;; all lists should be same length
           (let ((l 1))
             (assert
              (apply #'= (loop for x in (cons ret args)
                               when (listp x)
                                 collect (setf l (length x)) into ll
                               finally (return (or ll (list l))))))
             (loop for r in (ensure-list* ret l)
                   for a in (apply #'mapcar
                                   'list
                                   (mapcar (lambda (a) (ensure-list* a l))
                                           args))
                   collect (list a r)
                   append (loop with l = (length a)
                                for i from (or req l) below l
                                collect (list (subseq a 0 i) r))))))
  (let* ((*environment* 3bgl-glsl::*glsl-base-environment*)
         (*global-environment* 3bgl-glsl::*glsl-base-environment*)
         ;; meta-types for defining the overloads
         (scalar (list :bool :int :uint :float :double))
         (number (list :int :uint :float :double))
         (vec (list :vec2 :vec3 :vec4))
         (ivec (list :ivec2 :ivec3 :ivec4))
         (uvec (list :uvec2 :uvec3 :uvec4))
         (bvec (list :bvec2 :bvec3 :bvec4))
         (dvec (list :dvec2 :dvec3 :dvec4))
         (gvec4 (list :vec4 :ivec4 :uvec4))
         (mat (list :mat2 :mat3 :mat4 :mat2x3 :mat2x4 :mat3x2 :mat3x4 :mat4x3 :mat4x2))
         (dmat (list :dmat2 :dmat3 :dmat4 :dmat2x3 :dmat2x4 :dmat3x2 :dmat3x4 :dmat4x3 :dmat4x2))
         ;; for defining vector/matrix constructors
         ;;(2-vector (list :bvec2 :ivec2 :uvec2 :vec2 :dvec2))
         ;;(3-vector (list :bvec3 :ivec3 :uvec3 :vec3 :dvec3))
         ;;(4-vector (list :bvec4 :ivec4 :uvec4 :vec4 :dvec4))
         ;;(sqmat (list :mat2 :mat3 :mat4))
         (gen-type (cons :float vec))
         (gen-itype (cons :int ivec))
         (gen-utype (cons :uint uvec))
         (gen-btype (cons :bool bvec))
         (gen-dtype (cons :double dvec))
         ;; N scalars to simplify floatxvec and floatxmat signatures
         (fxv (make-list (length vec) :initial-element :float))
         (fxm (make-list (length mat) :initial-element :float))
         (dxv (make-list (length dvec) :initial-element :double))
         (dxm (make-list (length dmat) :initial-element :double))
         (ixv (make-list (length ivec) :initial-element :int))
         (uxv (make-list (length uvec) :initial-element :uint))
         ;; todo: decide if these should have signatures matching
         ;; implicit cats, or if those should be separate or not
         ;; available at all?
         (binop-args (make-ftype
                      (append gen-type gen-itype gen-utype gen-dtype
                              vec mat vec mat dvec dmat dvec dmat
                              ivec ivec uvec uvec
                              mat dmat)
                      (append gen-type gen-itype gen-utype gen-dtype
                              vec mat fxv fxm dvec dmat dxv dxm
                              ivec ixv uxv uvec
                              mat dmat)
                      (append gen-type gen-itype gen-utype gen-dtype
                              fxv fxm vec mat dxv dxm dvec dmat
                              ixv ivec uvec uxv
                              mat dmat)))
         (unary-gentypes+mats (make-ftype
                               (append gen-type gen-itype gen-utype gen-dtype
                                       mat dmat)
                               (append gen-type gen-itype gen-utype gen-dtype
                                       mat dmat)))
         (scalar-compare (make-ftype
                          (list :bool :bool :bool :bool)
                          (list :int :uint :float :double)
                          (list :int :uint :float :double)))
         (log* (make-ftype (append gen-itype gen-utype
                                   ivec ivec uvec uvec)
                           (append gen-itype gen-utype
                                   ivec ixv uvec uxv)
                           (append gen-itype gen-utype
                                   ixv ivec uxv uvec)))
         (sampler '(:sampler-1d :sampler-2d :sampler-3d :sampler-cube
                    :sampler-1d-shadow :sampler-2d-shadow
                    :sampler-cube-shadow
                    :sampler-cube-array :sampler-cube-array-shadow
                    :sampler-2d-rect :sampler-2d-rect-shadow
                    :sampler-1d-array :sampler-2d-array
                    :sampler-1d-array-shadow :sampler-2d-array-shadow
                    :sampler-buffer :sampler-2d-ms :sampler-2d-ms-array))
         (isampler '(:isampler-1d :isampler-2d :isampler-3d :isampler-cube
                     nil nil
                     nil
                     :isampler-cube-array nil
                     :isampler-2d-rect nil
                     :isampler-1d-array :isampler-2d-array
                     nil nil
                     :isampler-buffer :isampler-2d-ms :isampler-2d-ms-array))
         (usampler '(:usampler-1d :usampler-2d :usampler-3d :usampler-cube
                     nil nil
                     nil
                     :usampler-cube-array nil
                     :usampler-2d-rect nil
                     :usampler-1d-array :usampler-2d-array
                     nil nil
                     :usampler-buffer :usampler-2d-ms :usampler-2d-ms-array))
         (gsampler1d '(:sampler-1d :isampler-1d :usampler-1d))
         (gsampler2d '(:sampler-2d :isampler-2d :usampler-2d))
         (gsampler3d '(:sampler-3d :isampler-3d :usampler-3d))
         (gsamplercube '(:sampler-cube :isampler-cube :usampler-cube))
         (gsampler1darray '(:sampler-1d-array :isampler-1d-array
                            :usampler-1d-array))
         (gsampler2darray '(:sampler-2d-array :isampler-2d-array
                            :usampler-2d-array))
         (gsampler2drect '(:sampler-2d-rect :isampler-2d-rect :usampler-2d-rect))
         (gsamplercubearray '(:sampler-cube-array :isampler-cube-array :usampler-cube-array))
         (gsamplercubearrayshadow '(:sampler-cube-array-shadow :isampler-cube-array-shadow :usampler-cube-array-shadow))
         (gsamplerbuffer '(:sampler-buffer :isampler-buffer :usampler-buffer))

         (gsampler2dms '(:sampler-2d-ms :isampler-2d-ms :usampler-2d-ms))
         (gsampler2dmsarray '(:sampler-2d-ms-array :isampler-2d-ms-array :usampler-2d-ms-array))
         (sampler-parameters (make-hash-table)))
    (declare (ignorable usampler isampler sampler sampler-parameters))
    ;;
    ;; these are all assumed to be binary at this point, any n>2 -ary
    ;; uses should have been expanded to binary calls in earlier passes
    ;; todo: decide if unary + is worth adding?
    (add-internal-function/full '+ '(a b) binop-args)

    ;; not sure if - should have a unary version or just print
    ;; (- 0 x) as -x ?
    ;; unary version is probably easier for type inference
    (add-internal-function/full '- '(a &optional b)
                                (append binop-args
                                        ;; unary version
                                        unary-gentypes+mats))
    ;; expanding (/ x) to (1/x) in printer as well, in hopes of simplifying
    ;; type inference
    (add-internal-function/full '/ '(a &optional b)
                                (append binop-args
                                        unary-gentypes+mats))


    ;; fixme: verify the non-square matric types for *
    (add-internal-function/full '* '(a b)
                                `( ;; vec*vec is component-wise
                                  ((:ivec2 :ivec2) :ivec2)
                                  ((:uvec2 :uvec2) :uvec2)
                                  ((:vec2 :vec2) :vec2)
                                  ((:dvec2 :dvec2) :dvec2)
                                  ((:ivec3 :ivec3) :ivec3)
                                  ((:uvec3 :uvec3) :uvec3)
                                  ((:vec3 :vec3) :vec3)
                                  ((:dvec3 :dvec3) :dvec3)
                                  ((:ivec4 :ivec4) :ivec4)
                                  ((:uvec4 :uvec4) :uvec4)
                                  ((:vec4 :vec4) :vec4)
                                  ((:dvec4 :dvec4) :dvec4)
                                  ;; mat*mat, mat*vec
                                  ;;A right vector operand is treated as a
                                  ;;column vector and a left vector operand as
                                  ;;a row vector.
                                  ;; fixme: generate these?
                                  ;; 1xN Mx1 -> NxM
                                  ;; -x-
                                  ;; 2xN Mx2 -> MxN
                                  ((:vec2 :mat2) :vec2)
                                  ((:vec2 :mat3x2) :vec3)
                                  ((:vec2 :mat4x2) :vec4)
                                  ((:mat2 :vec2) :vec2)
                                  ((:mat3x2 :vec2) :vec3)
                                  ((:mat4x2 :vec2) :vec4)
                                  ((:mat2 :mat2) :mat2)
                                  ((:mat2 :mat3x2) :mat3x2)
                                  ((:mat2 :mat4x2) :mat4x2)
                                  ((:mat2x3 :mat2) :mat3x2)
                                  ((:mat2x3 :mat3x2) :mat3)
                                  ((:mat2x3 :mat4x2) :mat3x4)
                                  ((:mat2x4 :mat2) :mat4x2)
                                  ((:mat2x4 :mat3x2) :mat4x3)
                                  ((:mat2x4 :mat4x2) :mat4)
                                  ;; 3xN Mx3 -> MxN
                                  ((:vec3 :mat2x3) :vec2)
                                  ((:vec3 :mat3) :vec3)
                                  ((:vec3 :mat4x3) :vec4)
                                  ((:mat2x3 :vec3) :vec2)
                                  ((:mat3 :vec3) :vec3)
                                  ((:mat4x3 :vec3) :vec4)
                                  ((:mat3x2 :mat2x3) :mat2)
                                  ((:mat3x2 :mat3) :mat3x2)
                                  ((:mat3x2 :mat4x3) :mat4x2)
                                  ((:mat3 :mat2x3) :mat3x2)
                                  ((:mat3 :mat3) :mat3)
                                  ((:mat3 :mat4x3) :mat3x4)
                                  ((:mat3x4 :mat2x3) :mat4x2)
                                  ((:mat3x4 :mat3) :mat4x3)
                                  ((:mat3x4 :mat4x3) :mat4)
                                  ;; 4xN Mx4 -> MxN
                                  ((:vec4 :mat2x4) :vec2)
                                  ((:vec4 :mat3x4) :vec3)
                                  ((:vec4 :mat4) :vec4)
                                  ((:mat2x4 :vec4) :vec2)
                                  ((:mat3x4 :vec4) :vec3)
                                  ((:mat4 :vec4) :vec4)
                                  ((:mat4x2 :mat2x4) :mat2)
                                  ((:mat4x2 :mat3x4) :mat3x2)
                                  ((:mat4x2 :mat4) :mat4x2)
                                  ((:mat4x3 :mat2x4) :mat3x2)
                                  ((:mat4x3 :mat3x4) :mat3)
                                  ((:mat4x3 :mat4) :mat3x4)
                                  ((:mat4 :mat2x4) :mat4x2)
                                  ((:mat4 :mat3x4) :mat4x3)
                                  ((:mat4 :mat4) :mat4)
                                  ;; double
                                  ;; 2xN Mx2 -> MxN
                                  ((:dvec2 :dmat2) :dvec2)
                                  ((:dvec2 :dmat3x2) :dvec3)
                                  ((:dvec2 :dmat4x2) :dvec4)
                                  ((:dmat2 :dvec2) :dvec2)
                                  ((:dmat3x2 :dvec2) :dvec3)
                                  ((:dmat4x2 :dvec2) :dvec4)
                                  ((:dmat2 :dmat2) :dmat2)
                                  ((:dmat2 :dmat3x2) :dmat3x2)
                                  ((:dmat2 :dmat4x2) :dmat4x2)
                                  ((:dmat2x3 :dmat2) :dmat3x2)
                                  ((:dmat2x3 :dmat3x2) :dmat3)
                                  ((:dmat2x3 :dmat4x2) :dmat3x4)
                                  ((:dmat2x4 :dmat2) :dmat4x2)
                                  ((:dmat2x4 :dmat3x2) :dmat4x3)
                                  ((:dmat2x4 :dmat4x2) :dmat4)
                                  ;; 3xN Mx3 -> MxN
                                  ((:dvec3 :dmat2x3) :dvec2)
                                  ((:dvec3 :dmat3) :dvec3)
                                  ((:dvec3 :dmat4x3) :dvec4)
                                  ((:dmat2x3 :dvec3) :dvec2)
                                  ((:dmat3 :dvec3) :dvec3)
                                  ((:dmat4x3 :dvec3) :dvec4)
                                  ((:dmat3x2 :dmat2x3) :dmat2)
                                  ((:dmat3x2 :dmat3) :dmat3x2)
                                  ((:dmat3x2 :dmat4x3) :dmat4x2)
                                  ((:dmat3 :dmat2x3) :dmat3x2)
                                  ((:dmat3 :dmat3) :dmat3)
                                  ((:dmat3 :dmat4x3) :dmat3x4)
                                  ((:dmat3x4 :dmat2x3) :dmat4x2)
                                  ((:dmat3x4 :dmat3) :dmat4x3)
                                  ((:dmat3x4 :dmat4x3) :dmat4)
                                  ;; 4xN Mx4 -> MxN
                                  ((:dvec4 :dmat2x4) :dvec2)
                                  ((:dvec4 :dmat3x4) :dvec3)
                                  ((:dvec4 :dmat4) :dvec4)
                                  ((:dmat2x4 :dvec4) :dvec2)
                                  ((:dmat3x4 :dvec4) :dvec3)
                                  ((:dmat4 :dvec4) :dvec4)
                                  ((:dmat4x2 :dmat2x4) :dmat2)
                                  ((:dmat4x2 :dmat3x4) :dmat3x2)
                                  ((:dmat4x2 :dmat4) :dmat4x2)
                                  ((:dmat4x3 :dmat2x4) :dmat3x2)
                                  ((:dmat4x3 :dmat3x4) :dmat3)
                                  ((:dmat4x3 :dmat4) :dmat3x4)
                                  ((:dmat4 :dmat2x4) :dmat4x2)
                                  ((:dmat4 :dmat3x4) :dmat4x3)
                                  ((:dmat4 :dmat4) :dmat4)
                                  ;; scalars
                                  ((:int :int) :int)
                                  ((:uint :uint) :uint)
                                  ((:float :float) :float)
                                  ((:double :double) :double)
                                  ,@(make-ftype (append vec mat ivec uvec
                                                        vec mat ivec uvec)
                                                (append fxv fxm ixv uxv
                                                        vec mat ivec uvec)
                                                (append vec mat ivec uvec
                                                        fxv fxm ixv uxv))))
    ;; glsl % operator (no 2nd value from CL operator for now)
    ;; combined with glsl 'mod' function below
    #++
    (add-internal-function/full 'mod '(a b) (make-ftype
                                             (append gen-itype gen-utype
                                                     ivec uvec ivec uvec)
                                             (append gen-itype gen-utype
                                                     ivec uvec ixv uxv)
                                             (append gen-itype gen-utype
                                                     ixv uxv ivec uvec)))

    ;; glsl ++ and -- are post-[in/de]crement for now (incf/decf are pre)
    ;; (incf/decf work on vec/mat also, so might want to shadow cl:
    ;;  versions at some point)
    #++
    (add-internal-function/s '3bgl-glsl::incf '(a &optional b)
                             `((or ,@gen-type
                                   ,@gen-itype ,@gen-utype
                                   ,@gen-dtype ,@mat ,@dmat)
                               (=s 0))
                             '(= 0))
    #++
    (add-internal-function/s '3bgl-glsl::decf '(a &optional b)
                             `((or ,@gen-type
                                   ,@gen-itype ,@gen-utype
                                   ,@gen-dtype ,@mat ,@dmat)
                               (=s 0))
                             '(= 0))
    (add-internal-function/s '3bgl-glsl::++ '(a)
                             `((or ,@gen-type
                                   ,@gen-itype ,@gen-utype
                                   ,@gen-dtype ,@mat ,@dmat))
                             '(= 0)
                             :cast nil)
    (add-internal-function/s '3bgl-glsl::-- '(a)
                             `((or ,@gen-type
                                   ,@gen-itype ,@gen-utype
                                   ,@gen-dtype ,@mat ,@dmat))
                             '(= 0)
                             :cast nil)
    ;; should these work on vectors etc too?
    ;; (would need to be able to see types in printer to expand to
    ;;  lessThan etc)
    (add-internal-function/full '< '(a b) scalar-compare)
    (add-internal-function/full '> '(a b) scalar-compare)
    (add-internal-function/full '<= '(a b) scalar-compare)
    (add-internal-function/full '>= '(a b) scalar-compare)
    ;; args like (= ##) will be constrained to same type as arg ##
    ;; = is glsl == operator, /= is glsl !=
    ;; (possibly closer to equal or equalp in CL terms, since it works
    ;;  on aggregates and compares contents)
    (add-internal-function/s '= '(a b) '(T (= 0)) :bool)
    (add-internal-function/s '/= '(a b) '(T (= 0)) :bool)

    (add-internal-function/s 'zerop '(a) `((or ,@number)) :bool)
    (add-internal-function/s 'plusp '(a) `((or ,@number)) :bool)
    (add-internal-function/s 'minusp '(a) `((or ,@number)) :bool)

    ;; || && ^^
    (add-internal-function/full 'or '(a b) '(((:bool :bool) :bool))
                                :cast nil)
    (add-internal-function/full 'and '(a b) '(((:bool :bool) :bool))
                                :cast nil)
    (add-internal-function/full '3bgl-glsl::^^ '(a b) '(((:bool :bool) :bool))
                                :cast nil)
    ;; is this glsl '!' or glsl 'not' or both?
    ;; assuming we can get type info during printing to pick right one...
    (add-internal-function/full 'not '(a) (append
                                           '(((:bool) :bool))
                                           (make-ftype bvec bvec))
                                :cast nil)

    ;; ?: (if is handled as special operator, but might use this to
    ;; avoid building constraints by hand...)
    (add-internal-function/s '3bgl-glsl::|?:| '(c then else)
                             '(:bool T (= 1)) '(= 1))
    ;;(add-internal-function/s 'if (c then else) (:bool T (= 1)) (= 1))

    ;; ~
    (add-internal-function/s 'lognot '(a) `((or :int :uint ,@ivec ,@uvec))
                             '(= 0)
                             :cast nil)


    ;; fixme: verify types for <<
    ;; possibly also simplify?
    ;;  return is same type as first arg
    ;;  2nd arg is same size vec or scalar, but doesn't have to match
    ;;    signed vs unsigned
    (add-internal-function/full '3bgl-glsl::<< '(integer count)
                                `(((:int :int) :int)
                                  ((:int :uint) :int)
                                  ((:uint :int) :uint)
                                  ((:uint :uint) :uint)
                                  ,@(make-ftype (append ivec uvec ivec uvec
                                                        ivec uvec ivec uvec)
                                                (append ivec uvec ivec uvec
                                                        ivec uvec ivec uvec)
                                                (append ivec uvec uvec ivec
                                                        ixv uxv uxv ixv)))
                                :cast nil)
    (add-internal-function/full '3bgl-glsl::>> '(integer count)
                                `(((:int :int) :int)
                                  ((:int :uint) :int)
                                  ((:uint :int) :uint)
                                  ((:uint :uint) :uint)
                                  ,@(make-ftype (append ivec uvec ivec uvec
                                                        ivec uvec ivec uvec)
                                                (append ivec uvec ivec uvec
                                                        ivec uvec ivec uvec)
                                                (append ivec uvec uvec ivec
                                                        ixv uxv uxv ixv)))
                                :cast nil)

    (add-internal-function/full '3bgl-glsl::ash '(integer count)
                                `(((:int :int) :int)
                                  ((:int :uint) :int)
                                  ((:uint :int) :uint)
                                  ((:uint :uint) :uint)
                                  ,@(make-ftype (append ivec uvec ivec uvec
                                                        ivec uvec ivec uvec)
                                                (append ivec uvec ivec uvec
                                                        ivec uvec ivec uvec)
                                                (append ivec uvec uvec ivec
                                                        ixv uxv uxv ixv)))
                                :cast nil)

    ;; | & ^
    ;; fixme: do these allow casts?
    (add-internal-function/full 'logior '(a b) log* :cast nil)
    (add-internal-function/full 'logand '(a b) log* :cast nil)
    (add-internal-function/full 'logxor '(a b) log* :cast nil)


    ;; including 1+ and 1- to simplify type inference, so we don't have
    ;; to know what type of 1 to use
    (add-internal-function/full '1- '(number) unary-gentypes+mats
                                :cast nil)
    (add-internal-function/full '1+ '(number) unary-gentypes+mats
                                :cast nil)
    ;; todo ++, --


    (add-internal-function/s 'return '(value)
                             '(t) '(= 0))

    ;; fixme: most of these belong in 3bgl-glsl: package
    (macrolet ((add/s (&rest definitions)
                 `(progn
                    ,@(loop for (.name lambda-list arg-types return-type)
                              in definitions
                            for (name glsl-name . keys)
                              = (alexandria:ensure-list .name)
                            collect `(add-internal-function/s ',name
                                                              ',lambda-list
                                                              ,arg-types
                                                              ,return-type
                                                              :glsl-name
                                                              ,glsl-name
                                                              ,@keys))))
               (add/f (&rest definitions)
                 `(progn
                    ,@(loop for (.name lambda-list ftype)
                              in definitions
                            for (name glsl-name . keys)
                              = (alexandria:ensure-list .name)
                            collect `(add-internal-function/full ',name
                                                                 ',lambda-list
                                                                 ,ftype
                                                                 :glsl-name
                                                                 ,glsl-name
                                                                 ,@keys))))
               (add/f1 (&rest definitions)
                 `(progn
                    ,@(loop for (.name lambda-list args ret)
                              in definitions
                            for (name glsl-name . keys)
                              = (alexandria:ensure-list .name)
                            for ftype = `(mapcar (lambda (a) (list a ,ret))
                                                 ,args)
                            collect `(add-internal-function/full ',name
                                                                 ',lambda-list
                                                                 ,ftype
                                                                 :glsl-name
                                                                 ,glsl-name
                                                                 ,@keys))))
               (add/m (&rest definitions)
                 `(progn
                    ,@(loop for (.name lambda-list count ret)
                              in definitions
                            for (name glsl-name) = (alexandria:ensure-list
                                                    .name)
                            collect `(add-internal-function/mat ',name
                                                                ',lambda-list
                                                                ,count
                                                                ,ret
                                                                :glsl-name
                                                                ,glsl-name))))
               (expand-signatures (ret args &rest more-signatures)
                 (setf more-signatures (list* ret args more-signatures))
                 `(append
                   ,@(loop for (r a) on more-signatures by #'cddr
                           collect `(expand-signature ,r ,(cons 'list a)))))
               (expand-signatures/o ((req) ret args &rest more-signatures)
                 (setf more-signatures (list* ret args more-signatures))
                 `(append
                   ,@(loop for (r a) on more-signatures by #'cddr
                           collect `(expand-signature ,r ,(cons 'list a)
                                                      :req ,req)))))
      (add/s
       ;; 8.1 angle and trigonometry functions
       (3bgl-glsl:radians (degrees) `((or ,@gen-type)) `(= 0))
       (3bgl-glsl:degrees (radians) `((or ,@gen-type)) `(= 0))
       (sin (radians) `((or ,@gen-type)) `(= 0))
       (cos (radians) `((or ,@gen-type)) `(= 0))
       (tan (radians) `((or ,@gen-type)) `(= 0))
       (asin (radians) `((or ,@gen-type)) `(= 0))
       (acos (radians) `((or ,@gen-type)) `(= 0))
       (atan (y &optional x) `((or ,@gen-type) (= 0)) `(= 0))
       (sinh (x) `((or ,@gen-type)) `(= 0))
       (cosh (x) `((or ,@gen-type)) `(= 0))
       (tanh (x) `((or ,@gen-type)) `(= 0))
       (asinh (x) `((or ,@gen-type)) `(= 0))
       (acosh (x) `((or ,@gen-type)) `(= 0))
       (atanh (x) `((or ,@gen-type)) `(= 0))

       ;; 8.2 exponential functions
       (3bgl-glsl::pow (x y) `((or ,@gen-type) (= 0)) `(= 0))
       (exp (x) `((or ,@gen-type)) `(= 0))
       (log (x) `((or ,@gen-type)) `(= 0))
       (3bgl-glsl:exp2 (x) `((or ,@gen-type)) `(= 0))
       (3bgl-glsl:log2 (x) `((or ,@gen-type)) `(= 0))
       (sqrt (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       ((3bgl-glsl:inverse-sqrt "inversesqrt") (x)
        `((or ,@gen-type ,@gen-dtype)) `(= 0))

       ;; 8.3 common functions
       (abs (x) `((or ,@gen-type ,@gen-itype ,@gen-dtype)) `(= 0))
       ;; cl:signum -> 3bgl-glsl:sign
       (signum (x) `((or ,@gen-type ,@gen-itype ,@gen-dtype)) `(= 0))
       (3bgl-glsl:sign (x) `((or ,@gen-type ,@gen-itype ,@gen-dtype)) `(= 0))
       ;; todo: compiler macro to expand (floor number divisor) to
       ;; (floor (/ number divisor))?
       ;; (and same for truncate, round, ceiling, etc)
       (floor (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       ;; cl:truncate -> 3bgl-glsl::trunc
       (truncate (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       (3bgl-glsl:trunc (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       (round (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       (3bgl-glsl:round-even (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       (ceiling (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       (3bgl-glsl:ceil (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       (3bgl-glsl:fract (x) `((or ,@gen-type ,@gen-dtype)) `(= 0))
       ;; handled specially, expands to % for integral types,
       ;; mod() for float types, operates componentwise in both cases
       ;; if first argument is a vector type
       (mod (x y) `((or ,@gen-itype ,@gen-utype
                        ,@gen-type ,@gen-dtype) (=s 0)) `(= 0))
       (3bgl-glsl:modf (x y) `((or ,@gen-type ,@gen-dtype) (:out (=s 0)))
                        `(= 0))


       (min (x y) `((or ,@gen-type ,@gen-dtype ,@gen-itype ,@gen-utype) (=s 0))
            `(= 0))
       (max (x y) `((or ,@gen-type ,@gen-dtype ,@gen-itype ,@gen-utype) (=s 0))
            `(= 0))

       (3bgl-glsl:clamp (x min max)
                         `((or ,@gen-type ,@gen-dtype ,@gen-itype ,@gen-utype)
                           (=s 0) (=s 0)) '(= 0)))

      (add-internal-function/full '3bgl-glsl:mix '(x y a)
                                  (make-ftype
                                   ` (:float
                                      ,@vec ,@vec
                                      :double ,@dvec ,@dvec
                                      ,@gen-type ,@gen-dtype
                                      ,@gen-itype ,@gen-utype ,@gen-btype)
                                   `(:float
                                     ,@vec ,@vec
                                     :double ,@dvec ,@dvec
                                     ,@gen-type ,@gen-dtype
                                     ,@gen-itype ,@gen-utype ,@gen-btype)
                                   `(:float
                                     ,@vec ,@vec
                                     :double ,@dvec ,@dvec
                                     ,@gen-type ,@gen-dtype
                                     ,@gen-itype ,@gen-utype ,@gen-btype)
                                   `(:float
                                     ,@vec ,@fxv
                                     :double ,@dvec ,@dxv
                                     ,@gen-btype ,@gen-btype
                                     ,@gen-btype ,@gen-btype ,@gen-btype)))

      (add/s
       (3bgl-glsl:step (edge x) `((=s 1) (or ,@gen-type ,@gen-dtype)) '(= 1))
       ((3bgl-glsl:smooth-step "smoothstep") (edge0 edge1 x) `((=s 2)
                                                                (= 0)
                                                                (or ,@gen-type
                                                                    ,@gen-dtype))
        '(= 2))
       ((3bgl-glsl:is-nan "isnan") (x) `((or ,@gen-type ,@gen-dtype))
        `(=# 0 :bool))
       ((3bgl-glsl:is-inf "isinf") (x) `((or ,@gen-type ,@gen-dtype))
        `(=# 0 :bool))
       (3bgl-glsl:float-bits-to-int (value) `((or ,@gen-type))
                                     `(=# 0 :int))
       (3bgl-glsl:float-bits-to-uint (value) `((or ,@gen-type))
                                      `(=# 0 :uint))
       (3bgl-glsl:int-bits-to-float (value) `((or ,@gen-itype))
                                     `(=# 0 :float))
       (3bgl-glsl:uint-bits-to-float (value) `((or ,@gen-utype))
                                      `(=# 0 :float))
       (3bgl-glsl:fma (a b c) `((or ,@gen-type ,@gen-dtype) (= 0) (= 0)) '(= 0))
       (3bgl-glsl:frexp (x exp) `((or ,@gen-type ,@gen-dtype) (:out (=# 0 :int)))
                         '(= 0))
       (3bgl-glsl:ldexp (x exp) `((or ,@gen-type ,@gen-dtype) (=# 0 :int))
                         '(= 0))

       ;; 8.4 floating-point pack and unpack functions
       (3bgl-glsl:pack-unorm-2x16 (v) `(:vec2) :uint)
       (3bgl-glsl:pack-snorm-2x16 (v) `(:vec2) :uint)
       (3bgl-glsl:pack-unorm-4x8 (v) `(:vec2) :uint)
       (3bgl-glsl:pack-snorm-4x8 (v) `(:vec2) :uint)

       (3bgl-glsl:unpack-unorm-2x16 (v) `(:uint) :vec2)
       (3bgl-glsl:unpack-snorm-2x16 (v) `(:uint) :vec2)
       (3bgl-glsl:unpack-unorm-4x8 (v) `(:uint) :vec2)
       (3bgl-glsl:unpack-snorm-4x8 (v) `(:uint) :vec2)

       (3bgl-glsl:pack-double-2x32 (v) `(:uvec2) :double)
       (3bgl-glsl:unpack-double-2x32 (v) `(:double) :uvec2)

       (3bgl-glsl:pack-half-2x16 (v) `(:vec2) :uint)
       (3bgl-glsl:unpack-half-2x16 (v) `(:uint) :vec2)

       ;; 8.5 geometric functions
       ;; geometric length, not count of elements in sequence
       (3bgl-glsl:length (x) `((or ,@gen-type ,@gen-dtype)) '(s 0))
       (3bgl-glsl:distance (p0 p1) `((or ,@gen-type ,@gen-dtype) (= 0)) '(s 0))
       (3bgl-glsl:dot (x y) `((or ,@gen-type ,@gen-dtype) (= 0)) '(s 0))
       (3bgl-glsl:cross (x y) `((or :vec3 :dvec3) (= 0)) '(= 0))
       (3bgl-glsl:normalize (x) `((or ,@gen-type ,@gen-dtype)) '(= 0))
       ;; compat/vertex shader only
       (3bgl-glsl:ftransform () () :vec4)
       ((3bgl-glsl:face-forward "faceforward") (n i n-ref)
        `((or ,@gen-type ,@gen-dtype)
          (= 0)
          (= 0))
        '(= 0))
       (3bgl-glsl:reflect (i n) `((or ,@gen-type ,@gen-dtype) (= 0)) '(= 0))
       (3bgl-glsl:refract (i n eta) `((or ,@gen-type ,@gen-dtype) (= 0) :float)
                           '(= 0))


       ;; 8.6 matrix functions
       (3bgl-glsl::matrix-comp-mult (x y) `((or ,@mat ,@dmat) (= 0)) '(= 0)))

      (add-internal-function/full '3bgl-glsl::outer-product '(x y)
                                  (make-ftype
                                   '(:mat2 :mat3 :mat4
                                     :mat2x3 :mat3x2
                                     :mat2x4 :mat4x2
                                     :mat3x4 :mat4x3
                                     :dmat2 :dmat3 :dmat4
                                     :dmat2x3 :dmat3x2
                                     :dmat2x4 :dmat4x2
                                     :dmat3x4 :dmat4x3)
                                   '(:vec2 :vec3 :vec4
                                     :vec3 :vec2
                                     :vec4 :vec2
                                     :vec4 :vec3
                                     :dvec2 :dvec3 :dvec4
                                     :dvec3 :dvec2
                                     :dvec4 :dvec2
                                     :dvec4 :dvec3)
                                   '(:vec2 :vec3 :vec4
                                     :vec2 :vec3
                                     :vec2 :vec4
                                     :vec3 :vec4
                                     :dvec2 :dvec3 :dvec4
                                     :dvec2 :dvec3
                                     :dvec2 :dvec4
                                     :dvec3 :dvec4)))

      (add-internal-function/full '3bgl-glsl::transpose '(m)
                                  (make-ftype
                                   '(:mat2 :mat3 :mat4
                                     :mat2x3 :mat3x2
                                     :mat2x4 :mat4x2
                                     :mat3x4 :mat4x3
                                     :dmat2 :dmat3 :dmat4
                                     :dmat2x3 :dmat3x2
                                     :dmat2x4 :dmat4x2
                                     :dmat3x4 :dmat4x3)
                                   '(:mat2 :mat3 :mat4
                                     :mat3x2 :mat2x3
                                     :mat4x2 :mat2x4
                                     :mat4x3 :mat3x4
                                     :dmat2 :dmat3 :dmat4
                                     :dmat3x2 :dmat2x3
                                     :dmat4x2 :dmat2x4
                                     :dmat4x3 :dmat3x4)))

      (add/s
       (3bgl-glsl::determinant (m) `((or :mat2 :mat3 :mat4 :dmat2
                                         :dmat3 :dmat4))
                               '(= 0))
       (3bgl-glsl::inverse (m) `((or :mat2 :mat3 :mat4 :dmat2
                                     :dmat3 :dmat4)) '(= 0))


       ;; 8.7 vector relational functions
       (3bgl-glsl::less-than (x y) `((or ,@vec ,@ivec ,@uvec ,@dvec) (= 0))
                             '(=# 0 :bool))
       (3bgl-glsl::less-than-equal (x y) `((or ,@vec ,@ivec ,@uvec ,@dvec)
                                           (= 0))
                                   '(=# 0 :bool))
       (3bgl-glsl::greater-than (x y) `((or ,@vec ,@ivec ,@uvec ,@dvec) (= 0))
                                '(=# 0 :bool))
       (3bgl-glsl::greater-than-equal (x y) `((or ,@vec ,@ivec ,@uvec ,@dvec)
                                              (= 0))
                                      '(=# 0 :bool))
       ;; component-wise compare, unlike cl:equal
       (3bgl-glsl::equal (x y) `((or ,@vec ,@ivec ,@uvec ,@dvec ,@bvec) (= 0))
                         '(=# 0 :bool))
       (3bgl-glsl::not-equal (x y) `((or ,@vec ,@ivec ,@uvec ,@dvec ,@bvec)
                                     (= 0))
                             '(=# 0 :bool))
       (3bgl-glsl::any (x) `((or ,@bvec)) :bool)
       (3bgl-glsl::all (x) `((or ,@bvec)) :bool)
       ;; component-wise negation, unlike cl:not
       ;; merged with cl:not for now?
       ;; (3bgl-glsl::not (x) `((or ,@bvec)) '(= 0))


       ;; 8.8 integer functions
       (3bgl-glsl::uadd-carry (x y carry) `((or ,@gen-utype) (= 0) (:out (= 0)))
                              '(= 0))
       (3bgl-glsl::usub-borrow (x y borrow) `((or ,@gen-utype) (= 0)
                                              (:out (= 0)))
                               '(= 0))
       (3bgl-glsl::umul-extended (x y msb lsb) `((or ,@gen-utype) (= 0)
                                                 (:out (= 0)) (:out (= 0)))
                                 '(= 0))
       (3bgl-glsl::imul-extended (x y msb lsb) `((or ,@gen-itype) (= 0)
                                                 (:out (= 0)) (:out (= 0)))
                                 '(= 0))
       ;; todo: expand LDB/DPB to these?
       (3bgl-glsl::bitfield-extract (value offset bits)
                                    `((or ,@gen-itype ,@gen-utype) :int :int)
                                    '(= 0))
       (3bgl-glsl::bitfield-insert (base insert offset bits)
                                   `((or ,@gen-itype ,@gen-utype) (= 0)
                                     :int :int)
                                   '(= 0))
       (3bgl-glsl::bitfield-reverse (value) `((or ,@gen-itype ,@gen-utype))
                                    '(= 0))
       (3bgl-glsl::bit-count (value) `((or ,@gen-itype ,@gen-utype))
                             '(=# 0 :int))
       ((3bgl-glsl::find-lsb "findLSB") (value) `((or ,@gen-itype ,@gen-utype))
        '(=# 0 :int))
       ((3bgl-glsl::find-msb "findMSB") (value) `((or ,@gen-itype ,@gen-utype))
        '(=# 0 :int)))

      ;; 8.9 Texture Functions
      (add/f
       (3bgl-glsl::texture-size (sampler &optional lod)
                                (expand-signatures/o (1)
                                 :int (gsampler1D :int)
                                 :ivec2 (gsampler2D :int)
                                 :ivec3 (gsampler3D :int)
                                 :ivec2 (gsamplerCube :int)
                                 :int (:sampler-1D-Shadow :int)
                                 :ivec2 (:sampler-2D-Shadow :int)
                                 :ivec2 (:sampler-Cube-Shadow :int)
                                 :ivec3 (gsamplerCubeArray :int)
                                 :ivec3 (:sampler-Cube-Array-Shadow :int)
                                 :ivec2 (gsampler2DRect)
                                 :ivec2 (:sampler-2D-Rect-Shadow)
                                 :ivec2 (gsampler1DArray :int)
                                 :ivec3 (gsampler2DArray :int)
                                 :ivec2 (:sampler-1D-Array-Shadow :int)
                                 :ivec3 (:sampler-2D-Array-Shadow :int)
                                 :int (gsamplerBuffer)
                                 :ivec2 (gsampler2DMS)
                                 :ivec3 (gsampler2DMSArray)))


       (3bgl-glsl::texture-query-lod (sampler p)
                                     (expand-signatures
                                      :vec2 (gsampler1D :float)
                                      :vec2 (gsampler2D :vec2)
                                      :vec2 (gsampler3D :vec3)
                                      :vec2 (gsamplerCube :vec3)
                                      :vec2 (gsampler1DArray :float)
                                      :vec2 (gsampler2DArray :vec2)
                                      :vec2 (gsamplerCubeArray :vec3)
                                      :vec2 (:sampler-1D-Shadow :float)
                                      :vec2 (:sampler-2D-Shadow :vec2)
                                      :vec2 (:sampler-Cube-Shadow :vec3)
                                      :vec2 (:sampler-1D-Array-Shadow :float)
                                      :vec2 (:sampler-2D-Array-Shadow :vec2)
                                      :vec2 (:sampler-Cube-Array-Shadow :vec3)))
       (3bgl-glsl::texture-query-levels '(sampler)
                                        (expand-signatures
                                         :int (gsampler1D)
                                         :int (gsampler2D)
                                         :int (gsampler3D)
                                         :int (gsamplerCube)
                                         :int (gsampler1DArray)
                                         :int (gsampler2DArray)
                                         :int (gsamplerCubeArray)
                                         :int (:sampler-1D-Shadow)
                                         :int (:sampler-2D-Shadow)
                                         :int (:sampler-Cube-Shadow)
                                         :int (:sampler-1D-Array-Shadow)
                                         :int (:sampler-2D-Array-Shadow)
                                         :int (:sampler-CubeArray-Shadow))))

      (add-internal-function/s '3bgl-glsl::texture-samples '(s)
                               `((or ,@gsampler2dms
                                     ,@gsampler2dmsarray))
                               :int)
      (add/f
       (3bgl-glsl::texture (sampler p &optional bias/compare)
                           (expand-signatures/o (2)
                            gvec4 (gsampler1D :float :float)
                            gvec4 (gsampler2D :vec2 :float)
                            gvec4 (gsampler3D :vec3 :float)
                            gvec4 (gsamplerCube :vec3 :float)
                            :float (:sampler-1D-Shadow :vec3 :float)
                            :float (:sampler-2D-Shadow :vec3 :float)
                            :float (:sampler-Cube-Shadow :vec4 :float)
                            gvec4 (gsampler1DArray :vec2 :float)
                            gvec4 (gsampler2DArray :vec3 :float)
                            gvec4 (gsamplerCubeArray :vec4 :float)
                            :float (:sampler-1D-Array-Shadow :vec3 :float)
                            :float (:sampler-2D-Array-Shadow :vec4 :float)
                            ;; no bias/compare for 2drect
                            gvec4 (gsampler2DRect :vec2)
                            :float (:sampler-2D-Rect-Shadow :vec3)
                            :float (gsamplerCubeArrayShadow :vec4 :float)))

       (3bgl-glsl::texture-proj (sampler p &optional bias)
                                (expand-signatures/o (2)
                                 gvec4 (gsampler1D :vec2 :float)
                                 gvec4 (gsampler1D :vec4 :float)
                                 gvec4 (gsampler2D :vec3 :float)
                                 gvec4 (gsampler2D :vec4 :float)
                                 gvec4 (gsampler3D :vec4 :float)
                                 :float (:sampler-1D-Shadow :vec4 :float)
                                 :float (:sampler-2D-Shadow :vec4 :float)
                                 gvec4 (gsampler2DRect :vec3)
                                 gvec4 (gsampler2DRect :vec4)
                                 :float (:sampler-2D-Rect-Shadow :vec4)))

       (3bgl-glsl::texture-lod (sampler p lod)
                               (expand-signatures
                                gvec4 (gsampler1D :float :float)
                                gvec4 (gsampler2D :vec2 :float)
                                gvec4 (gsampler3D :vec3 :float)
                                gvec4 (gsamplerCube :vec3 :float)
                                :float (:sampler-1D-Shadow :vec3 :float)
                                :float (:sampler-2D-Shadow :vec3 :float)
                                gvec4 (gsampler1DArray :vec2 :float)
                                gvec4 (gsampler2DArray :vec3 :float)
                                :float (:sampler-1D-Array-Shadow
                                        :vec3 :float)
                                gvec4 (gsamplerCubeArray :vec4 :float)))
       (3bgl-glsl::texture-offset (sampler p offset &optional bias)
                                  (expand-signatures/o (3)
                                   gvec4 (gsampler1D :float :int :float)
                                   gvec4 (gsampler2D :vec2 :ivec2 :float)
                                   gvec4 (gsampler3D :vec3 :ivec3 :float)
                                   gvec4 (gsampler2DRect :vec2 :ivec2)
                                   :float (:sampler-2D-Rect-Shadow :vec3 :ivec2)
                                   :float (:sampler-1D-Shadow :vec3 :int :float)
                                   :float (:sampler-2D-Shadow
                                           :vec3 :ivec2 :float)
                                   gvec4 (gsampler1DArray :vec2 :int :float)
                                   gvec4 (gsampler2DArray :vec3 :ivec2 :float)
                                   :float (:sampler-1D-Array-Shadow
                                           :vec3 :int :float)
                                   :float (:sampler-2D-Array-Shadow
                                           :vec4 :ivec2)))


       (3bgl-glsl::texel-fetch (sampler p &optional lod/sample)
                               (expand-signatures/o (2)
                                gvec4 (gsampler1D :int :int)
                                gvec4 (gsampler2D :ivec2 :int)
                                gvec4 (gsampler3D :ivec3 :int)
                                gvec4 (gsampler2DRect :ivec2)
                                gvec4 (gsampler1DArray :ivec2 :int)
                                gvec4 (gsampler2DArray :ivec3 :int)
                                gvec4 (gsamplerBuffer :int)
                                gvec4 (gsampler2DMS :ivec2 :int)
                                gvec4 (gsampler2DMSArray :ivec3 :int)))

       (3bgl-glsl::texel-fetch-offset (sampler P lod offset)
                                      (expand-signatures
                                       gvec4 (gsampler1D :int :int :int)
                                       gvec4 (gsampler2D :ivec2 :int :ivec2)
                                       gvec4 (gsampler3D :ivec3 :int :ivec3)
                                       gvec4 (gsampler2DRect :ivec2 :ivec2)
                                       gvec4 (gsampler1DArray :ivec2 :int :int)
                                       gvec4 (gsampler2DArray :ivec3 :int :ivec2)))

       (3bgl-glsl::texture-proj-offset (sampler p offset &optional bias)
                                       (expand-signatures/o (3)
                                        gvec4 (gsampler1D :vec2 :int :float)
                                        gvec4 (gsampler1D :vec4 :int :float)
                                        gvec4 (gsampler2D :vec3 :ivec2 :float)
                                        gvec4 (gsampler2D :vec4 :ivec2 :float)
                                        gvec4 (gsampler3D :vec4 :ivec3 :float)
                                        gvec4 (gsampler2DRect :vec3 :ivec2)
                                        gvec4 (gsampler2DRect :vec4 :ivec2)
                                        :float (:sampler-2D-Rect-Shadow
                                                :vec4 :ivec2)
                                        :float (:sampler-1D-Shadow
                                                :vec4 :int :float)
                                        :float (:sampler-2D-Shadow
                                                :vec4 :ivec2 :float)))
       (3bgl-glsl::texture-lod-offset (sampler p lod offset)
                                      (expand-signatures
                                       gvec4 (gsampler1D :float :float :int)
                                       gvec4 (gsampler2D :vec2 :float :ivec2)
                                       gvec4 (gsampler3D :vec3 :float :ivec3)
                                       :float (:sampler-1D-Shadow
                                               :vec3 :float :int)
                                       :float (:sampler-2D-Shadow
                                               :vec3 :float :ivec2)
                                       gvec4 (gsampler1DArray
                                              :vec2 :float :int)
                                       gvec4 (gsampler2DArray
                                              :vec3 :float :ivec2)
                                       :float (:sampler-1D-Array-Shadow
                                               :vec3 :float :int)))
       (3bgl-glsl::texture-proj-lod (sampler o lod)
                                    (expand-signatures
                                     gvec4 (gsampler1D :vec2 :float)
                                     gvec4 (gsampler1D :vec4 :float)
                                     gvec4 (gsampler2D :vec3 :float)
                                     gvec4 (gsampler2D :vec4 :float)
                                     gvec4 (gsampler3D :vec4 :float)
                                     :float (:sampler-1D-Shadow :vec4 :float)
                                     :float (:sampler-2D-Shadow
                                             :vec4 :float)))
       (3bgl-glsl::texture-proj-lod-offset
        (sampler p lod offset)
        (expand-signatures
         gvec4 (gsampler1D :vec2 :float :int)
         gvec4 (gsampler1D :vec4 :float :int)
         gvec4 (gsampler2D :vec3 :float :ivec2)
         gvec4 (gsampler2D :vec4 :float :ivec2)
         gvec4 (gsampler3D :vec4 :float :ivec3)
         :float (:sampler-1D-Shadow :vec4 :float :int)
         :float (:sampler-2D-Shadow :vec4 :float :ivec2)))
       (3bgl-glsl::texture-grad (sampler p dP/dx dP/dy)
                                (expand-signatures
                                 gvec4 (gsampler1D :float :float :float)
                                 gvec4 (gsampler2D :vec2 :vec2 :vec2)
                                 gvec4 (gsampler3D :vec3 :vec3 :vec3)
                                 gvec4 (gsamplerCube :vec3 :vec3 :vec3)
                                 gvec4 (gsampler2DRect :vec2 :vec2 :vec2)
                                 :float (:sampler-2D-Rect-Shadow
                                         :vec3 :vec2 :vec2)
                                 :float (:sampler-1D-Shadow :vec3 :float :float)
                                 :float (:sampler-2D-Shadow :vec3 :vec2 :vec2)
                                 :float (:sampler-Cube-Shadow :vec4 :vec3 :vec3)
                                 gvec4 (gsampler1DArray :vec2 :float :float)
                                 gvec4 (gsampler2DArray :vec3 :vec2 :vec2)
                                 :float (:sampler-1D-Array-Shadow
                                         :vec3 :float :float)
                                 :float (:sampler-2D-Array-Shadow
                                         :vec4 :vec2 :vec2)
                                 gvec4 (gsamplerCubeArray :vec4 :vec3 :vec3)))
       (3bgl-glsl::texture-grad-offset
        (sampler p dp/dx dp/dy offset)
        (expand-signatures
         gvec4 (gsampler1D :float :float :float :int)
         gvec4 (gsampler2D :vec2 :vec2 :vec2 :ivec2)
         gvec4 (gsampler3D :vec3 :vec3 :vec3 :ivec3)
         gvec4 (gsampler2DRect :vec2 :vec2 :vec2 :ivec2)
         :float (:sampler-2D-Rect-Shadow :vec3 :vec2 :vec2 :ivec2)
         :float (:sampler-1D-Shadow :vec3 :float :float :int)
         :float (:sampler-2D-Shadow :vec3 :vec2 :vec2 :ivec2)
         gvec4 (gsampler1DArray :vec2 :float :float :int)
         gvec4 (gsampler2DArray :vec3 :vec2 :vec2 :ivec2)
         :float (:sampler-1D-Array-Shadow :vec3 :float :float :int)
         :float (:sampler-2D-Array-Shadow :vec4 :vec2 :vec2 :ivec2)))
       (3bgl-glsl::texture-proj-grad
        (sampler p dp/dx dp/dy)
        (expand-signatures
         gvec4 (gsampler1D :vec2 :float :float)
         gvec4 (gsampler1D :vec4 :float :float)
         gvec4 (gsampler2D :vec3 :vec2 :vec2)
         gvec4 (gsampler2D :vec4 :vec2 :vec2)
         gvec4 (gsampler3D :vec4 :vec3 :vec3)
         gvec4 (gsampler2DRect :vec3 :vec2 :vec2)
         gvec4 (gsampler2DRect :vec4 :vec2 :vec2)
         :float (:sampler-2D-Rect-Shadow :vec4 :vec2 :vec2)
         :float (:sampler-1D-Shadow :vec4 :float :float)
         :float (:sampler-2D-Shadow :vec4 :vec2 :vec2)))
       (3bgl-glsl::texture-proj-grad-offset
        (sampler p dp/dx dp/dy offset)
        (expand-signatures
         gvec4 (gsampler1D :vec2 :float :float :int)
         gvec4 (gsampler1D :vec4 :float :float :int)
         gvec4 (gsampler2D :vec3 :vec2 :vec2 :ivec2)
         gvec4 (gsampler2D :vec4 :vec2 :vec2 :ivec2)
         gvec4 (gsampler2DRect :vec3 :vec2 :vec2 :ivec2)
         gvec4 (gsampler2DRect :vec4 :vec2 :vec2 :ivec2)
         :float (:sampler-2D-Rect-Shadow :vec4 :vec2 :vec2 :ivec2)
         gvec4 (gsampler3D :vec4 :vec3 :vec3 :ivec3)
         :float (:sampler-1D-Shadow :vec4 :float :float :int)
         :float (:sampler-2D-Shadow :vec4 :vec2 :vec2 :ivec2)))

       ;; 8.9.3 texture gather functions
       (3bgl-glsl::texture-gather (sampler p refz)
                                  (expand-signatures
                                   gvec4 (gsampler2D :vec2 :int)
                                   gvec4 (gsampler2DArray :vec3 :int)
                                   gvec4 (gsamplerCube :vec3 :int)
                                   gvec4 (gsamplerCubeArray :vec4 :int)
                                   gvec4 (gsampler2DRect :vec2 :int)
                                   :vec4 (:sampler-2D-Shadow :vec2 :float)
                                   :vec4 (:sampler-2D-Array-Shadow :vec3 :float)
                                   :vec4 (:sampler-Cube-Shadow :vec3 :float)
                                   :vec4 (:sampler-Cube-Array-Shadow
                                          :vec4 :float)
                                   :vec4 (:sampler-2D-Rect-Shadow
                                          :vec2 :float)))
       (3bgl-glsl::texture-gather-offset
        (sampler p refz offset)
        (expand-signatures
         gvec4 (gsampler2D :vec2 :ivec2 :int)
         gvec4 (gsampler2DArray :vec3 :ivec2 :int)
         gvec4 (gsampler2DRect :vec2 :ivec2 :int)
         :vec4 (:sampler-2D-Shadow :vec2 :float :ivec2)
         :vec4 (:sampler-2D-Array-Shadow :vec3 :float :ivec2)
         :vec4 (:sampler-2D-Rect-Shadow :vec2 :float :ivec2)))
       ;; fixme: figure out/implement syntax for array params
       #++
       (3bgl-glsl::texture-gather-offsets
        (sampler o offsets &optional comp)
        (expand-signatures
         gvec4 (gsampler2D :vec2 (:ivec2 4) :int)
         gvec4 (gsampler2DArray :vec3 (:ivec2 4) :int)
         gvec4 (gsampler2DRect :vec2 (:ivec2 4) :int)
         :vec4 (:sampler-2D-Shadow :vec2 :float (:ivec2 4))
         :vec4 (:sampler-2D-Array-Shadow :vec3 :float (:ivec2 4))
         :vec4 (:sampler-2D-Rect-Shadow :vec2 :float (:ivec2 4)))))

      ;; 8.9.4 compatibility profile

      (add/s
       ((3bgl-glsl::texture-1d "texture1D") (sampler coord &optional bias)
        '(:sampler-1d :float :float) :vec4)
       ((3bgl-glsl::texture-1d-proj "texture1DProj")
        (sampler coord &optional bias)
        '(:sampler-1d (or :vec2 :vec4) :float) :vec4)
       ((3bgl-glsl::texture-1d-lod "texture1DLod") (sampler coord lod)
        '(:sampler-1d :float :float) :vec4)
       ((3bgl-glsl::texture-1d-proj-lod "texture1DProjLod") (sampler coord lod)
        '(:sampler-1d (or :vec2 :vec4) :float)
        :vec4)

       ((3bgl-glsl::texture-2d "texture2D")
        (sampler coord &optional bias) '(:sampler-2d :vec2 :float) :vec4)
       ((3bgl-glsl::texture-2d-proj "texture2DProj")
        (sampler coord &optional bias)
        '(:sampler-2d (or :vec3 :vec4) :float) :vec4)
       ((3bgl-glsl::texture-2d-lod "texture2DLod") (sampler coord lod)
        '(:sampler-2d :vec2 :float) :vec4)
       ((3bgl-glsl::texture-2d-proj-lod "texture2DProjLod") (sampler coord lod)
        '(:sampler-2d (or :vec3 :vec4) :float)
        :vec4)

       ((3bgl-glsl::texture-3d "texture3D") (sampler coord &optional bias)
        '(:sampler-3d :vec3 :float) :vec4)
       ((3bgl-glsl::texture-3d-proj "texture3DProj")
        (sampler coord &optional bias)
        '(:sampler-3d :vec4 :float) :vec4)
       ((3bgl-glsl::texture-3d-lod "texture3DLod") (sampler coord lod)
        '(:sampler-3d :vec3 :float) :vec4)
       ((3bgl-glsl::texture-3d-proj-lod "texture3DProjLod") (sampler coord lod)
        '(:sampler-3d :vec4 :float) :vec4)


       (3bgl-glsl::texture-cube (sampler coord &optional bias)
                                '(:sampler-3d :vec3 :float) :vec4)
       (3bgl-glsl::texture-cube-lod (sampler coord lod)
                                    '(:sampler-3d :vec3 :float) :vec4)


       ((3bgl-glsl::shadow-1d "shadow1D") (sampler coord &optional bias)
        '(:sampler-1d-shadow :vec3 :float) :vec4)
       ((3bgl-glsl::shadow-2d "shadow2D") (sampler coord &optional bias)
        '(:sampler-2d-rect-shadow :vec3 :float) :vec4)
       ((3bgl-glsl::shadow-1d-proj "shadow1DProj")
        (sampler coord &optional bias)
        '(:sampler-1d-shadow :vec4 :float) :vec4)
       ((3bgl-glsl::shadow-2d-proj "shadow2DProj")
        (sampler coord &optional bias)
        '(:sampler-1d-shadow :vec4 :float) :vec4)
       ((3bgl-glsl::shadow-1d-lod "shadow1DLod") (sampler coord lod)
        '(:sampler-1d-shadow :vec3 :float) :vec4)
       ((3bgl-glsl::shadow-2d-lod "shadow2DLod") (sampler coord lod)
        '(:sampler-1d-shadow :vec3 :float) :vec4)
       ((3bgl-glsl::shadow-1d-proj-lod "shadow1DProjLod") (sampler coord lod)
        '(:sampler-1d-shadow :vec4 :float) :vec4)
       ((3bgl-glsl::shadow-2d-proj-lod "shadow2DProjLod") (sampler coord lod)
        '(:sampler-1d-shadow :vec4 :float) :vec4))

      ;; 8.10 atomic-counter functions
      (add/s
       (3bgl-glsl::atomic-counter-increment (c) '(:atomic-uint) :uint)
       (3bgl-glsl::atomic-counter-decrement (c) '(:atomic-uint) :uint)
       (3bgl-glsl::atomic-counter (c) '(:atomic-uint) :uint))

      ;; 8.11 atomic memory functions
      (add/s
       ;; fixme: add a more descriptive type for 1st arg
       ;; ("coherent inout" in spec, should at least reject casts on first arg
       ;;   probably also restrict to components of buffers/shared variables
       ;;   as described in spec)
       (3bgl-glsl::atomic-add (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-min (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-max (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-and (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-or (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-xor (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-exchange (mem data) '((or :uint :int) (= 0)) '(= 0))
       (3bgl-glsl::atomic-comp-swap (mem compare data)
                                    '((or :uint :int) (= 0) (= 0)) '(= 0)))

      ;; 8.12 Image functions
      (let ((gimage1d '(:image-1d :iimage-1d :uimage-1d))
            (gimage2d '(:image-2d :iimage-2d :uimage-2d))
            (gimage3d '(:image-3d :iimage-3d :uimage-3d))
            (gimage2drect '(:image-2d-rect :iimage-2d-rect :uimage-2d-rect))
            (gimagecube '(:image-cube :iimage-cube :uimage-cube))
            (gimagebuffer '(:image-buffer :iimage-buffer :uimage-buffer))
            (gimage1darray '(:image-1d-array :iimage-1d-array :uimage-1d-array))
            (gimage2darray '(:image-2d-array :iimage-2d-array :uimage-2d-array))
            (gimagecubearray '(:image-cube-array :iimage-cube-array
                               :uimage-cube-array))
            (gimage2dms '(:image-2d-ms :iimage-2d-ms :uimage-2d-ms))
            (gimage2dmsarray '(:image-2d-ms-array :iimage-2d-ms-array
                               :uimage-2d-ms-array))
            (gscalar '(:float :int :uint)))
        (macrolet ((image-params ((&optional (mask 7)) ret args &rest more-sigs)
                     (setf more-sigs (list* ret args more-sigs))
                     `(flet ((x (l)
                               (loop for e in l
                                     for i from 0
                                     when (logbitp i ,mask)
                                       collect e)))
                        (append
                         ,@(loop
                             for (ret args) on more-sigs by #'cddr
                             collect `(x (expand-signature
                                          ,ret (list gimage1d :int ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage2d :ivec2 ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage3d :ivec3 ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage2drect :ivec2 ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimagecube :ivec3 ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimagebuffer :int ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage1darray
                                                     :ivec2 ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage2darray
                                                     :ivec3 ,@args)))
                             collect  `(x (expand-signature
                                           ,ret (list gimagecubearray :ivec3
                                                      ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage2dms :ivec2 :int ,@args)))
                             collect `(x (expand-signature
                                          ,ret (list gimage2dmsarray :ivec3 :int
                                                     ,@args))))))))
          (add/f
           (3bgl-glsl::image-size (image)
                                  (expand-signatures
                                   :int (gimage1D)
                                   :ivec2 (gimage2D)
                                   :ivec3 (gimage3D)
                                   :ivec2 (gimageCube)
                                   :ivec3 (gimageCubeArray)
                                   :ivec2 (gimage2DRect)
                                   :ivec2 (gimage1DArray)
                                   :ivec3 (gimage2DArray)
                                   :int (gimageBuffer)
                                   :ivec2 (gimage2DMS)
                                   :ivec3 (gimage2DMSArray)))
           (3bgl-glsl::image-samples (image)
                                     (expand-signatures
                                      :int (gimage2DMS)
                                      :int (gimage2DMSArray)))
           (3bgl-glsl::image-load (image p &optional sample)
                                  (image-params () gvec4 ()))
           ;; fixme: figure out some better way to specify args for overloads?
           ;; (image p data) or (image2dms* p sample data)
           (3bgl-glsl::image-store (image p data/sample &optional data)
                                   (image-params () :void (gvec4)))
           ;; 6 = int/uint, 7=all ;; fixme: make that more obvious
           (3bgl-glsl::image-atomic-add (image p data/sample &optional data)
                                        (image-params (6) gscalar (gscalar)))
           (3bgl-glsl::image-atomic-min (image p data/sample &optional data)
                                        (image-params (6) gscalar (gscalar)))
           (3bgl-glsl::image-atomic-max (image p data/sample &optional data)
                                        (image-params (6) gscalar (gscalar)))
           (3bgl-glsl::image-atomic-and (image p data/sample &optional data)
                                        (image-params (6) gscalar (gscalar)))
           (3bgl-glsl::image-atomic-or (image p data/sample &optional data)
                                       (image-params (6) gscalar (gscalar)))
           (3bgl-glsl::image-atomic-xor (image p data/sample &optional data)
                                        (image-params (6) gscalar (gscalar)))
           ;; allowing float is new in 4.5 (spec claims it returns :int though?)
           (3bgl-glsl::image-atomic-exchange (image p data/sample &optional data)
                                             (image-params (7) gscalar (gscalar)))
           ;;(image p compare data) or (image2dms* p sample compare data)
           (3bgl-glsl::image-atomic-comp-swap (image p data/compare compare/data
                                                     &optional data)
                                              (image-params (6) gscalar
                                                            (gscalar gscalar))))))

      ;; 8.13 fragment processing functions
      (add/s
       ;; 8.13.1 derivative functions
       ((3bgl-glsl:dfdx "dFdx") (p) `((or ,@gen-type)) '(= 0))
       ((3bgl-glsl:dfdy "dFdy") (p) `((or ,@gen-type)) '(= 0))
       ((3bgl-glsl:dfdx-fine "dFdxFine") (p) `((or ,@gen-type)) '(= 0))
       ((3bgl-glsl:dfdy-fine "dFdyFine") (p) `((or ,@gen-type)) '(= 0))
       ((3bgl-glsl:dfdx-coarse "dFdxCoarse") (p) `((or ,@gen-type)) '(= 0))
       ((3bgl-glsl:dfdy-coarse "dFdyCoarse") (p) `((or ,@gen-type)) '(= 0))
       (3bgl-glsl:fwidth (p) `((or ,@gen-type)) '(= 0))
       (3bgl-glsl:fwidth-fine (p) `((or ,@gen-type)) '(= 0))
       (3bgl-glsl:fwidth-coarse (p) `((or ,@gen-type)) '(= 0))

       ;; 8.13.2 interpolation functions
       ;; these specify float/vec2/vec3/vec4 explicitly instead of gentype?
       (3bgl-glsl::interpolate-at-centroid (interpolant) `((or ,@gen-type)) '(= 0))
       (3bgl-glsl::interpolate-at-sample (interpolant sample)
                                         `((or ,@gen-type) :int) '(= 0))
       (3bgl-glsl::interpolate-at-centroid (interpolant offset)
                                           `((or ,@gen-type) :vec2) '(= 0)))


      ;; 8.14 noise functions
      (add/s
       (3bgl-glsl::noise1 (x) `((or ,@gen-type)) :float)
       (3bgl-glsl::noise2 (x) `((or ,@gen-type)) :vec2)
       (3bgl-glsl::noise3 (x) `((or ,@gen-type)) :vec3)
       (3bgl-glsl::noise4 (x) `((or ,@gen-type)) :vec4))

      ;; 8.15 geometry shader functions
      ;; todo: restrict these to geometry shaders
      (add/s
       ((3bgl-glsl::emit-stream-vertex "EmitStreamVertex") (stream) '(:int)
        :void)
       ((3bgl-glsl::end-stream-primitive "EndStreamPrimitive") (stream) '(:int)
        :void)
       ((3bgl-glsl::emit-vertex "EmitVertex") () '() :void)
       ((3bgl-glsl::end-primitive "EndPrimitive") () '() :void))

      ;; 8.16 shader invocation control functions
      ;; todo: restrict to tessellation control and compute shaders
      (add/s
       (3bgl-glsl::barrier () () :void))

      ;; 8.17 Shader memory control functions
      ;; all shader types
      (add/s
       (3bgl-glsl::memory-barrier () () :void)
       (3bgl-glsl::memory-barrier-atomic-counter () () :void)
       (3bgl-glsl::memory-barrier-buffer () () :void)
       (3bgl-glsl::memory-barrier-shared () () :void)
       (3bgl-glsl::memory-barrier-image () () :void)
       (3bgl-glsl::group-memory-barrier () () :void))

      ;; 8.19 Shader Invocation Group Functions
      (add/s
       (3bgl-glsl::any-invocation (value) `(:bool) :bool)
       (3bgl-glsl::all-invocations (value) `(:bool) :bool)
       (3bgl-glsl::all-invocations-equal (value) `(:bool) :bool))

      ;; vector/matrix constructors

      (add/s
       ;; not completely sure if mat is allowed here?
       ;; might also allow arrays?
       (3bgl-glsl::int (x) `((or :int :uint :bool :float
                      :double ,@ivec ,@uvec ,@vec ,@dvec ,@mat)) :int)
       (3bgl-glsl::uint (x) `((or :int :uint :bool :float
                       :double  ,@ivec ,@uvec ,@vec ,@dvec ,@mat)) :uint)
       (3bgl-glsl::bool (x) `((or :int :uint :bool :float
                       :double ,@ivec ,@uvec ,@vec ,@dvec ,@mat)) :bool)
       (float (x) `((or :int :uint :bool :float
                        :double ,@ivec ,@uvec ,@vec ,@dvec ,@mat)) :float)
       (3bgl-glsl::double (x) `((or :int :uint :bool :float
                         :double ,@ivec ,@uvec ,@vec ,@dvec ,@mat)) :double))

      (labels ((vec/mat-constructor (n &optional (base :float))
                 (let ((foo '((:bool ((:bvec2 2) (:bvec3 3) (:bvec4 4)))
                              (:int ((:ivec2 2) (:ivec3 3) (:ivec4 4)))
                              (:uint ((:uvec2 2) (:uvec3 3) (:uvec4 4)))
                              (:float ((:vec2 2) (:vec3 3) (:vec4 4)))
                              (:double ((:dvec2 2) (:dvec3 3) (:dvec4 4))))))
                   (if (zerop n)
                       (list nil)
                       (loop for (type count) in
                             `(,@(mapcar (lambda (a) (list a 1)) scalar)
                               ,@(cadr (assoc base foo)))
                             when (<= count n)
                               append (mapcar (lambda (a) (cons type a))
                                              (vec/mat-constructor (- n count)
                                                                   base))))))))

      (add/m
       (3bgl-glsl::bvec2 (a &optional b) 2 :bvec2)
       (3bgl-glsl::bvec3 (a &optional b c) 3 :bvec3)
       (3bgl-glsl::bvec4 (a &optional b c d) 4 :bvec4)

       (3bgl-glsl::i8vec2 (a &optional b) 2 :i8vec2)
       (3bgl-glsl::i8vec3 (a &optional b c) 3 :i8vec3)
       (3bgl-glsl::i8vec4 (a &optional b c d) 4 :i8vec4)
       (3bgl-glsl::u8vec2 (a &optional b) 2 :u8vec2)
       (3bgl-glsl::u8vec3 (a &optional b c) 3 :u8vec3)
       (3bgl-glsl::u8vec4 (a &optional b c d) 4 :u8vec4)

       (3bgl-glsl::i16vec2 (a &optional b) 2 :i16vec2)
       (3bgl-glsl::i16vec3 (a &optional b c) 3 :i16vec3)
       (3bgl-glsl::i16vec4 (a &optional b c d) 4 :i16vec4)
       (3bgl-glsl::u16vec2 (a &optional b) 2 :u16vec2)
       (3bgl-glsl::u16vec3 (a &optional b c) 3 :u16vec3)
       (3bgl-glsl::u16vec4 (a &optional b c d) 4 :u16vec4)

       (3bgl-glsl::ivec2 (a &optional b) 2 :ivec2)
       (3bgl-glsl::ivec3 (a &optional b c) 3 :ivec3)
       (3bgl-glsl::ivec4 (a &optional b c d) 4 :ivec4)
       (3bgl-glsl::uvec2 (a &optional b) 2 :uvec2)
       (3bgl-glsl::uvec3 (a &optional b c) 3 :uvec3)
       (3bgl-glsl::uvec4 (a &optional b c d) 4 :uvec4)

       (3bgl-glsl::i64vec2 (a &optional b) 2 :i64vec2)
       (3bgl-glsl::i64vec3 (a &optional b c) 3 :i64vec3)
       (3bgl-glsl::i64vec4 (a &optional b c d) 4 :i64vec4)
       (3bgl-glsl::u64vec2 (a &optional b) 2 :u64vec2)
       (3bgl-glsl::u64vec3 (a &optional b c) 3 :u64vec3)
       (3bgl-glsl::u64vec4 (a &optional b c d) 4 :u64vec4)

       (3bgl-glsl::f16vec2 (a &optional b) 2 :f16vec2)
       (3bgl-glsl::f16vec3 (a &optional b c) 3 :f16vec3)
       (3bgl-glsl::f16vec4 (a &optional b c d) 4 :f16vec4)

       (3bgl-glsl::vec2 (a &optional b) 2 :vec2)
       (3bgl-glsl::vec3 (a &optional b c) 3 :vec3)
       (3bgl-glsl::vec4 (a &optional b c d) 4 :vec4)

       (3bgl-glsl::dvec2 (a &optional b) 2 :dvec2)
       (3bgl-glsl::dvec3 (a &optional b c) 3 :dvec3)
       (3bgl-glsl::dvec4 (a &optional b c d) 4 :dvec4)

       (3bgl-glsl::mat2 (a &optional b c d) 4 :mat2)
       (3bgl-glsl::mat2x3 (a &optional b c d e f) 6 :mat2x3)
       (3bgl-glsl::mat2x4 (a &optional b c d e f g h) 8 :mat2x4)
       (3bgl-glsl::mat3x2 (a &optional b c d e f) 6 :mat3x2)
       (3bgl-glsl::mat3 (a &optional b c d e f g h i) 9  :mat3)
       (3bgl-glsl::mat3x4 (a &optional b c d e f g h i j k l) 12  :mat3x4)
       (3bgl-glsl::mat4x2 (a &optional b c d e f g h) 8  :mat4x2)
       (3bgl-glsl::mat4x3 (a &optional b c d e f g h i j k l) 12 :mat4x3)
       (3bgl-glsl::mat4 (a &optional b c d e f g h i j k l m n o p) 16 :mat4))
      ;; todo :dmat*

      (add/s
       (values (&optional v) '(t) '(= 0)))
      (add/s
       ;; return type is listed as T here to simplify unifying
       ;; branches of something like (if x (discard) (setf foo bar)).
       ;; type inference treats it like (return), so only works in
       ;; void functions
       (3bgl-glsl::discard () '() t)))))

;; define compiler macros for binary ops like + which accept any
;; number of args in CL
;; todo: add compiler macros for more complicated cases like =, <, etc
(macrolet ((define-binop (x)
             `(%glsl-compiler-macro ,x (&whole w &rest r)
                (labels ((rec (rr)
                           (if (> (length rr) 2)
                               `(,(car w) ,(rec (cdr rr)) ,(car rr))
                               `(,(car w) ,(cadr rr) ,(car rr)))))
                  (if (> (length r) 2)
                      (rec (reverse r))
                      w))))
           (define-binops (&rest r)
             `(progn
                ,@(loop for i in r collect `(define-binop ,i)))))
  (define-binops + - / * and or logior logxor logand))

;;; fixme: type inference isn't working properly for INCF/DECF
;; R gets gets i8vec3 or something like that from (defun foo () (let
;; (r) (incf r (vec3 1 2 3)))) so expanding to x=x+n for now...
(%glsl-compiler-macro '3bgl-glsl::incf (a &optional b)
  `(setf ,a (+ ,a ,(or b 1))))
(%glsl-compiler-macro '3bgl-glsl::decf (a &optional b)
  `(setf ,a (- ,a ,(or b 1))))
