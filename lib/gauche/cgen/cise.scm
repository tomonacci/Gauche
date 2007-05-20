;;;
;;; gauche.cgen.cise - C in S expression
;;;  
;;;   Copyright (c) 2004-2007  Shiro Kawai  <shiro@acm.org>
;;;   
;;;   Redistribution and use in source and binary forms, with or without
;;;   modification, are permitted provided that the following conditions
;;;   are met:
;;;   
;;;   1. Redistributions of source code must retain the above copyright
;;;      notice, this list of conditions and the following disclaimer.
;;;  
;;;   2. Redistributions in binary form must reproduce the above copyright
;;;      notice, this list of conditions and the following disclaimer in the
;;;      documentation and/or other materials provided with the distribution.
;;;  
;;;   3. Neither the name of the authors nor the names of its contributors
;;;      may be used to endorse or promote products derived from this
;;;      software without specific prior written permission.
;;;  
;;;   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
;;;   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
;;;   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
;;;   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
;;;   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
;;;   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
;;;   TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
;;;   PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
;;;   LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;;   NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;;   SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;  
;;;  $Id: cise.scm,v 1.1 2007-05-20 04:55:15 shirok Exp $
;;;

(define-module gauche.cgen.cise
  (use srfi-1)
  (use gauche.sequence)
  (use gauche.parameter)
  (use gauche.cgen.unit)
  (use util.match)
  (use util.list)
  (export cise-render
          cise-emit-source-line
          define-cise-macro
          )
  )
(select-module gauche.cgen.cise)

;; NB: a small experiment to see how I feel this...
;;  [@ a b c d] => (ref (ref (ref a b) c) d)
;; In string interpolations I have to use ,(@ ...) instead of ,[@ ...], for
;; the previous versions of interpolation code doesn't like #`",[...]".
;; Ideally this should be a compiler-macro (we can't make it a macro,
;; for we want to say (set! [@ x'y] val).
(define @
  (getter-with-setter
   (case-lambda
     ((obj selector) (ref obj selector))
     ((obj selector . more) (apply @ (ref obj selector) more)))
   (case-lambda
     ((obj selector val) ((setter ref) obj selector val))
     ((obj selector selector2 . rest)
      (apply (setter ref) (ref obj selector) selector2 rest)))))
;; end experiment

;;=============================================================
;; Parameters
;;

;; If true, include #line directive in the output.
(define cise-emit-source-line (make-parameter #t))

;;=============================================================
;; Environment
;;

;; Environment must be treated opaque from outside of CISE module.

(define-class <cise-env> ()
  ((context :init-keyword :context :init-value 'stmt) ; stmt or expr
   (decls   :init-keyword :decls   :init-value '())   ; list of extra decls
   ))

(define (make-env context decls)
  (make <cise-env> :context context :decls decls))
(define (env-ctx env)   [@ env'context])
(define (env-decls env) [@ env'decls])
(define (expr-ctx? env) (eq? (env-ctx env) 'expr))
(define (stmt-ctx? env) (eq? (env-ctx env) 'stmt))

(define (null-env)      (make-env 'stmt '()))

(define (expr-env env)
  (if (expr-ctx? env) env (make-env 'expr (env-decls env))))
(define (stmt-env env)
  (if (stmt-ctx? env) env (make-env 'stmt (env-decls env))))

(define (ensure-stmt-ctx form env)
  (unless (stmt-ctx? env)
    (error "cise: statment appears in an expression context:" form)))

(define (env-decl-add! env decl)
  (push! [@ env'decls] decl))

(define (wrap-expr form env)
  (if (stmt-ctx? env) `(,form ";") form))

(define (render-env-decls env)
  (map (match-lambda
         ((var type) `(,(cise-render-type type)" ",var";")))
       (env-decls env)))

;; Check source-info attribute of the input S-expr, and returns Stree
;; of "#line" line if necessary.
(define (source-info form env)
  ;; NB: source-info-ref would be included in future versions of Gauche,
  ;; but we need it locally here to make stub generation work with 0.8.10.
  ;; Remove this after 0.8.11 (or 0.9) release.
  (define (source-info-ref obj)
    (and (pair? obj)
         ((with-module gauche.internal pair-attribute-get)
          obj 'source-info #f)))
  (if (not (cise-emit-source-line))
    '()
    (match (source-info-ref form)
      (((? string? file) line)
       `((source-info ,file ,line)))
      (_ '()))))
   
;;=============================================================
;; Expander
;;
;;  Cgen expander knows little about C.  It handles literals
;;  (strings, numbers, booleans, and characters) and function calls.
;;  All other stuff is handled by "cise macros"
;;

(define *cgen-macro* (make-hash-table 'eq?))

(define-syntax define-cise-macro
  (syntax-rules ()
    ((_ (op form env) . body)
     (hash-table-put! *cgen-macro* 'op (lambda (form env) . body)))))

;; cise-render sexpr &optional port as-expr?
(define (cise-render form . opts)
  (let-optionals* opts ((port (current-output-port))
                        (expr #f))
    (define current-file #f)
    (define current-line 1)
    (define (render-finish stree)
      (match stree
        [('source-info (? string? file) line)
         (cond ((and (equal? file current-file) (eqv? line current-line)))
               ((and (equal? file current-file) (eqv? line (+ 1 current-line)))
                (inc! current-line)
                (format port "\n"))
               (else
                (set! current-file file)
                (set! current-line line)
                (format port "\n#line ~a ~s\n" line file)))]
        [(x . y) (render-finish x) (render-finish y)]
        [(? (any-pred string? symbol? number?) x) (display x port)]
        [_ #f]))
    
    (let* ((env ((if expr expr-env identity) (null-env)))
           (stree (render-rec form env)))
      (render-finish `(,@(render-env-decls env) ,stree)))))

;; render-rec :: Sexpr, Env -> Stree
(define (render-rec form env)
  (match form
    [((? symbol? key) . args)
     (cond ((hash-table-get *cgen-macro* key #f)
            => (lambda (expander) (render-rec (expander form env) env)))
           (else
            (let1 eenv (expr-env env)
              (wrap-expr
               `(,@(source-info form env)
                 ,(cise-render-identifier key) "("
                 ,@(intersperse "," (map (cut render-rec <> eenv) args))
                 ")")
               env))))]
    [(x . y)     form]   ; already stree
    [(? symbol?) (wrap-expr (cise-render-identifier form) env)]
    [(? identifier?) (wrap-expr (cise-render-identifier (unwrap-syntax form))
                                env)]
    [(? string?) (wrap-expr (write-to-string form) env)]
    [(? real?)   (wrap-expr form env)]
    [()          '()]
    [#\'         (wrap-expr "'\\''"  env)]
    [#\\         (wrap-expr "'\\\\'" env)]
    [#\newline   (wrap-expr "'\\n'"  env)]
    [#\return    (wrap-expr "'\\r'"  env)]
    [#\tab       (wrap-expr "'\\t'"  env)]
    [(? char?)   (wrap-expr `("'" ,(string form) "'") env)]
    [#t          (wrap-expr "TRUE" env)]
    [#f          (wrap-expr "FALSE" env)]
    [_           (error "Invalid CISE form: " form)]))

;;=============================================================
;; Built-in macros
;;

;;------------------------------------------------------------
;; Syntax
;;
(define-cise-macro (begin form env)
  (ensure-stmt-ctx form env)
  (match form
    ((_ . forms)
     `("{" ,@(map (cut render-rec <> env) forms) "}"))))

(define-cise-macro (let* form env)
  (ensure-stmt-ctx form env)
  (match form
    [(_ ((var ':: type . init) ...) . body)
     (let1 eenv (expr-env env)
       `(begin ,@(map (lambda (var type init)
                        `(,(cise-render-type type)" "
                          ,(cise-render-identifier var)
                          ,@(cond-list ((pair? init)
                                        `("=",(render-rec (car init) eenv))))
                          ";"))
                      var type init)
               ,@(map (cut render-rec <> env) body)))]
    ))

(define-cise-macro (if form env)
  (ensure-stmt-ctx form env)
  (let1 eenv (expr-env env)
    (match form
      [(_ test then)
       `("if (",(render-rec test eenv)")"
         ,(render-rec then env))]
      [(_ test then else)
       `("if (",(render-rec test eenv)")"
         ,(render-rec then env)" else " ,(render-rec else env))]
      )))

(define-cise-macro (when form env)
  (ensure-stmt-ctx form env)
  (match form
    [(_ test . forms) `(if ,test (begin ,@forms))]))

(define-cise-macro (unless form env)
  (ensure-stmt-ctx form env)
  (match form
    [(_ test . forms) `(if (not ,test) (begin ,@forms))]))

(define-cise-macro (for form env)
  (ensure-stmt-ctx form env)
  (let1 eenv (expr-env env)
    (match form
      [(_ (start test update) . body)
       `("for (",(render-rec start eenv)"; "
         ,(render-rec test eenv)"; "
         ,(render-rec update eenv)")"
         ,(render-rec `(begin ,@body) env))]
      [(_ () . body)
       `("for (;;)" ,(render-rec `(begin ,@body) env))]
      )))

(define-cise-macro (loop form env)
  (ensure-stmt-ctx form env)
  `(for () ,@(cdr form)))

(define-cise-macro (for-each form env)
  (ensure-stmt-ctx form env)
  (let ((eenv (expr-env env))
        (tmp  (gensym "cise__")))
    (match form
      [(_ ('lambda (var) . body) list-expr)
       (env-decl-add! env `(,tmp ScmObj))
       `("SCM_FOR_EACH(" ,(cise-render-identifier tmp) ","
         ,(render-rec list-expr eenv) ") {"
         ,(render-rec `(let* ((,var :: ScmObj (SCM_CAR ,tmp)))
                         ,@body) env)
         "}")])))

(define-cise-macro (pair-for-each form env)
  (ensure-stmt-ctx form env)
  (let ((eenv (expr-env env)))
    (match form
      [(_ ('lambda (var) . body) list-expr)
       `("SCM_FOR_EACH(" ,(cise-render-identifier var) ","
         ,(render-rec list-expr eenv) ")"
         ,(render-rec `(begin ,@body) env)
         )])))


(define-cise-macro (return form env)
  (ensure-stmt-ctx form env)
  (match form
    [(_ expr) `("return (" ,(render-rec expr (expr-env env)) ");")]))

(define-cise-macro (break form env)
  (ensure-stmt-ctx form env)
  (match form [(_) '("break;")]))

(define-cise-macro (continue form env)
  (ensure-stmt-ctx form env)
  (match form [(_) '("continue;")]))

(define-cise-macro (cond form env)
  (ensure-stmt-ctx form env)
  (let1 eenv (expr-env env)
    (define (a-clause test rest)
      `("(" ,(render-rec test eenv) ")" ,(render-rec `(begin ,@rest) env)))
    (match form
      [(_ (test . rest) ...)
       (fold-right (lambda (test rest r)
                     (cond
                      [(and (null? r) (eq? test 'else))
                       `(" else ",(render-rec `(begin ,@rest) env))]
                      [(eq? test (caadr form)) ; first form
                       `("if ",(a-clause test rest) ,@r)]
                      [else
                       `("else if" ,(a-clause test rest) ,@r)]))
                   '() test rest)]
      )))

(define-cise-macro (case form env)
  (ensure-stmt-ctx form env)
  (let1 eenv (expr-env env)
    (match form
      [(_ expr (literals . clause) ...)
       `("switch (",(render-rec expr eenv)") {"
         ,@(map (lambda (literals clause)
                  `(,@(if (eq? literals 'else)
                        '("default: ")
                        (map (lambda (literal) `("case ",literal" : "))
                             literals))
                    ,@(render-rec `(begin ,@clause) env)))
                literals clause)
         "}")]
      )))

;;------------------------------------------------------------
;; Operators
;;

(define-macro (define-nary op sop)
  `(define-cise-macro (,op form env)
     (let1 eenv (expr-env env)
       (wrap-expr
        (match form
          [(_ a)
           (list ,sop "("(render-rec a eenv)")")]
          [(_ a b)
           (list "("(render-rec a eenv)")",sop"("(render-rec b eenv)")")]
          [(_ a b . x)
           (list* ',op (list ',op a b) x)])
        env))))
       
(define-nary + "+")
(define-nary - "-")
(define-nary * "*")
(define-nary / "/")

(define-nary and "&&")
(define-nary or  "||")

(define-macro (define-unary op sop)
  `(define-cise-macro (,op form env)
     (wrap-expr
      (match form
        [(_ a)   (list ,sop "("(render-rec a (expr-env env))")")])
      env)))

(define-unary not    "!")
(define-unary lognot "~")
(define-unary &      "&")               ; only unary op

(define-unary pre++  "++")
(define-unary pre--  "--")

(define-macro (define-binary op sop)
  `(define-cise-macro (,op form env)
     (wrap-expr
      (match form
        [(_ a b)
         (list "("(render-rec a (expr-env env))")",sop
               "("(render-rec b (expr-env env))")")])
      env)))

(define-binary %       "%")
(define-binary logior  "|")
(define-binary logxor  "^")
(define-binary logand  "&")
(define-binary <       "<")
(define-binary <=      "<=")
(define-binary >       ">")
(define-binary >=      ">=")
(define-binary ==      "==")
(define-binary !=      "!=")
(define-binary <<      "<<")
(define-binary >>      ">>")

(define-binary +=      "+=")
(define-binary -=      "-=")
(define-binary *=      "*=")
(define-binary /=      "/=")
(define-binary %=      "%=")
(define-binary <<=     "<<=")
(define-binary >>=     ">>=")

(define-binary logior= "|=")
(define-binary logxor= "^=")
(define-binary logaor= "&=")

(define-macro (define-referencer op sop)
  `(define-cise-macro (,op form env)
     (let1 eenv (expr-env env)
       (wrap-expr
        (match form
          [(_ a b ...)
           (list "("(render-rec a eenv)")",sop
                 (intersperse ,sop (map cise-render-identifier b)))])
        env))))

(define-referencer ->  "->")
(define-referencer ref ".")

(define-cise-macro (?: form env)
  (let1 eenv (expr-env env)
    (wrap-expr
     (match form
       [(?: test then else)
        (list "(("(render-rec test eenv)")?("
              (render-rec then eenv)"):("
              (render-rec else eenv)"))")])
     env)))

(define-cise-macro (set! form env)
  (let1 eenv (expr-env env)
    (let loop ((args (cdr form)) (r '()))
      (match args
        [()  (wrap-expr (intersperse "," (reverse r)) env)]
        [(var val . more)
         (loop (cddr args)
               `((,(render-rec var eenv)"=",(render-rec val eenv)) ,@r))]
        [_   (error "uneven args for set!:" form)]))))

(define-cise-macro (result form env)
  (match form
    [(_ expr) `(set! SCM_RESULT ,expr)]))

;;=============================================================
;; Other utilities
;;

(define (cise-render-type typespec)
  (x->string typespec))                 ;for the time being

(define (cise-render-identifier sym)
  (cgen-safe-name-friendly (x->string sym)))

(provide "gauche/cgen/cise")
