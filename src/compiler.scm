
(load "define.scm")

;;;;;;;;;;;;;;;;;;;;        compile        ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (meaning-toplevel e*)
  (define (a-meaning-toplevel e tail?)
    (if (and (pair? e) (eq? (car e) 'define))
      (meaning-define e tail?)
      (meaning e (init-cenv) tail?)))

  (if (null? e*)
    (instruction-encode 'return)
    (let rec ([e* e*])
      (if (null? (cdr e*))
        (append
          (a-meaning-toplevel (car e*) #t)
          (instruction-encode 'return))
        (let ([m1 (a-meaning-toplevel (car e*) #f)])
          (append m1 (rec (cdr e*))))))))

(define (meaning e cenv tail?)
  (cond
   [(or (boolean? e)
        (number? e)
        (string? e)
        (char? e))
    (meaning-quote e cenv tail?)]
   [(symbol? e)
    (meaning-reference e cenv tail?)]
   [else
    (if (pair? e)
        (if (and (symbol? (car e))
                 (let ([addr (get-variable-address (car e) cenv)])
                   (and (global-address? addr)
                        (macro? (cdr (get-global
                                      (global-address-index addr)))))))
            (let ([mac (cdr (get-global
                             (global-address-index
                              (get-variable-address (cdr e)))))])
              (if (builtin-special-form? mac)
                  (case (special-form-symbol mac)
                    [(quote)      (meaning-quote (cadr e) cenv tail?)]
                    [(if)         (meaning-if (cadr e) (caddr e) (cadddr e) cenv tail?)]
                    [(set!)       (meaning-set (cadr e) (caddr e) cenv tail?)]
                    [(define)     (compile-error "define only allowed at top level")]
                    [(lambda)     (meaning-lambda (cadr e) (cddr e) cenv tail?)]
                    [(begin)      (meaning-sequence (cdr e) cenv tail?)]
                    [(and)        (meaning-and/or (cdr e) cenv tail? #t)]
                    [(or)         (meaning-and/or (cdr e) cenv tail? #f)]
                    ;; [(cond)       (meaning-cond (cdr e) cenv tail?)]
                    ;; [(let)        (meaning-let (cadr e) (cddr e) cenv tail?)]
                    ;; [(letrec)     (meaning-letrec (cadr e) (cddr e) cenv tail?)]
                    ;; [(quasiquote) (meaning-quasiquote (cadr e) cenv tail?)])
                  (meaning (expand-macro mac e cenv) cenv tail?)))
            (if (list? e)
                (meaning-application e cenv tail?)
                (compile-error "Invalid application" e))))
        (compile-error "Invalid syntax" e))]))

(define (expand-macro mac e cenv)
  ((macro-handler mac) e cenv))

(define (meaning-quote c cenv tail?)
  (if (or (boolean? c)
            (number? c)
            (pair? c)
            (null? c)
            (vector? c)
            (string? c)
            (char? c)
            (symbol? c))
        (case c
          [(#f) (instruction-encode 'const/false)]
          [(#t) (instruction-encode 'const/true)]
          [(()) (instruction-encode 'const/null)]
          [(0)  (instruction-encode 'const/0)]
          [(1)  (instruction-encode 'const/1)]
          [else (instruction-encode 'const (get-constant-index c))])
        (compile-error "Invalid quotation" c))))

(define (meaning-if e1 e2 e3 cenv tail?)
  (let* ([m1 (meaning e1 cenv #f)]
         [m2 (meaning e2 cenv tail?)]
         [m3 (meaning e3 cenv tail?)]
         [m2/goto (append m2 (gen-goto 'goto (length m3)))])
    (append m1 (gen-goto 'goto-if-false (length m2/goto))
            m2/goto
            m3)))

(define (meaning-define e tail?)
  (if (pair? (cadr e))
    ;; (define (f . args) . body)  =>  (set! f (lambda args) . body)
    (meaning `(set! ,(caadr e)
                (lambda ,(cdadr e)
                  . ,(cddr e)))
             (init-cenv) tail?)
    ;; (define x e)  =>  (set! x e)
    (meaning `(set! ,(cadr e)
                ,(caddr e))
             (init-cenv) tail?)))

(define (meaning-set name e cenv tail?)
  (append
    (meaning e cenv #f)
    (let ([addr (get-variable-address name cenv)])
      (cond
        [(local-address? addr)
         (if (zero? (local-address-depth addr))
             (instruction-encode 'shallow-set
                                 (local-address-index addr))
             (instruction-encode 'deep-set
                                 (local-address-depth addr)
                                 (local-address-index addr)))]
        [(global-address? addr)
         (instruction-encode 'global-set
                             (global-address-index addr))]
        [else
         (error 'meaning-set "unreachable")]))))

(define (meaning-reference name cenv tail?)
  (let ([addr (get-variable-address name cenv)])
    (cond
      [(local-address? addr)
       (if (zero? (local-address-depth addr))
           (instruction-encode 'shallow-ref
                               (local-address-index addr))
           (instruction-encode 'deep-ref
                               (local-address-depth addr)
                               (local-address-index addr)))]
      [(global-address? addr)
       (instruction-encode 'global-ref
                           (global-address-index addr))]
      [else
       (error 'meaing-reference "unreachable")])))

(define (meaning-sequence e+ cenv tail?)
  (let loop ([e+ e+])
    (if (null? (cdr e+))
      (meaning (car e+) cenv tail?)
      (let ([m1 (meaning (car e+) cenv #f)])
        (append m1 (loop (cdr e+)))))))

(define (meaning-cond e+ cenv tail?)
  ;; (cond [e1 . body] ...)
  ;; =>
  ;; (if e1 (begin . body) . ...)
  (letrec ([cvt (lambda (e+)
                  (cond
                    [(null? e+) #f]
                    [(and (null? (cdr e+))
                          (eq? (caar e+) 'else))
                     `(begin . ,(cdar e+))]
                    [else
                      `(if ,(caar e+)
                         (begin . ,(cdar e+))
                         ,(cvt (cdr e+)))]))])
    (meaning (cvt e+) cenv tail?)))

(define (meaning-let vv* body cenv tail?)
  ;; (let ([name value] ...) . body)
  ;; =>
  ;; ((lambda (name ...) . body) value ...)
  (meaning `((lambda ,(map car vv*) . ,body)
             . ,(map cadr vv*))
           cenv tail?))

(define (meaning-letrec vv* body cenv tail?)
  ;; (letrec ([name value] ...) . body)
  ;; =>
  ;; ((lambda (name ...) (set! name value) ... . body) #f ...)
  (meaning `((lambda ,(map car vv*)
               ,@(map (lambda (p)
                        `(set! ,(car p) ,(cadr p)))
                      vv*)
               ,@body)
             ,@(map not vv*))
           cenv tail?))

(define (meaning-and/or e* cenv tail? is-and?)
  (if (null? e*)
    (meaning is-and? cenv tail?)
    (let rec ([e+ e*])
      (if (null? (cdr e+))
        (meaning (car e+) cenv tail?)
        (let ([m1* (rec (cdr e+))])
          (append (meaning (car e+) cenv #f)
                  (gen-goto (if is-and?
                              'goto-if-false
                              'goto-if-true)
                            (length m1*))
                  m1*))))))

(define (meaning-lambda args body cenv tail?)
  (let* ([m (append (gen-lambda-body args body cenv #t)
                    (instruction-encode 'return))]
         [size (length m)])
    (append (instruction-encode 'closure
                                (modulo size 256)
                                (quotient size 256))
            m)))

(define (gen-lambda-body args body cenv tail?)
  (let ([n (variadic? args)])
    (append 
      (if n
        (instruction-encode 'varfunc n)
        (instruction-encode 'func (length args)))
      (meaning-sequence
        body
        (extend-cenv args cenv)
        tail?))))

(define (meaning-application e+ cenv tail?)
  (let loop ([e* (cdr e+)])
    (if (null? e*)
      (if (and (pair? (car e+))
               (eq? 'lambda (caar e+)))
        (gen-closed-application (car e+) (length (cdr e+)) cenv tail?)
        (append (meaning (car e+) cenv #f)
                (instruction-encode (if tail? 'tail-call 'call)
                                    (length (cdr e+)))))
      (append (meaning (car e*) cenv #f)
              (instruction-encode 'push)
              (loop (cdr e*))))))

(define (gen-closed-application e argc cenv tail?)
  (append (instruction-encode 'extend-env argc)
          (gen-lambda-body (cadr e) (cddr e) cenv tail?)
          (if tail?
            '()
            (instruction-encode 'shrink-env))))

(define (meaning-quasiquote e cenv tail?)
  (let* ([const? #t]
         [exp (let f ([e e] [lv 0])
                (cond
                 [(or (boolean? e)
                      (number? e)
                      (string? e)
                      (char? e))
                  e]
                 [(null? e)
                  ''()]
                 [(symbol? e)
                  `',e]
                 [(vector? e)
                  `(list->vector ,(f (vector->list e) lv))]
                 [(pair? e)
                  (cond
                   [(let ([e1 (car e)])
                      (and (pair? e1)
                           (pair? (cdr e1))
                           (null? (cddr e1))
                           (eq? (car e1) 'unquote-splicing)))
                    (if (zero? lv)
                        (begin
                          (set! const? #f)
                          `(append ,(cadar e) ,(f (cdr e) lv)))
                        (list 'cons (list ''unquote-splicing (f (cadar e) (- lv 1)))
                              (f (cdr e) lv)))]
                   [(and (pair? (cdr e))
                         (null? (cddr e)))
                    (case (car e)
                      [(quasiquote)
                       (list 'list ''quasiquote (f (cadr e) (+ lv 1)))]
                      [(unquote)
                       (if (zero? lv)
                           (begin
                             (set! const? #f)
                             (cadr e))
                           (list 'list ''unquote (f (cadr e) (- lv 1))))]
                      [else
                       (list 'cons (f (car e) lv)
                             (f (cdr e) lv))])]
                   [else
                    (list 'cons (f (car e) lv)
                          (f (cdr e) lv))])]
                 [else
                  (compile-error "Invalid quasiquotation" e)]))])
    (if const?
        (meaning-quote e cenv tail?)
        (meaning exp cenv tail?))))

;;;;;;;;;;;;;;;;;;  auxiliary functions

(define (gen-goto code offset)
  (if (> offset 65535)
    (compile-error "too long jump" offset)
    (instruction-encode code
                        (modulo offset 256)
                        (quotient offset 256))))

(define-record-type local-address (fields depth index))
(define-record-type global-address (fields index))

(define (get-variable-address name cenv)
  (let loop ([cenv cenv] [i 0])
    (if (null? cenv)
        (make-global-address (get-global-index name))
       (let loop2 ([rib (car cenv)] [j 0])
         (cond
           [(null? rib)
            (loop (cdr cenv) (+ i 1))]
           [(eq? (car rib) name)
            (make-local-address i j)]
           [else
            (loop2 (cdr rib) (+ j 1))])))))


(define (init-cenv) '())

(define (extend-cenv v* cenv)
  (letrec ([f (lambda (v*)
                (cond
                  [(null? v*) '()]
                  [(symbol? v*) (cons v* '())]
                  [else
                    (cons (car v*) (f (cdr v*)))]))])
    (cons (f v*) cenv)))

(define (variadic? v*)
  (let loop ([v* v*] [i 0])
    (cond
     [(null? v*) #f]
     [(atom? v*) i]
     [else (loop (cdr v*) (+ i 1))])))
