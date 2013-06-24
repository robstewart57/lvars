#lang racket

(module language racket
  (require "LVish.rkt")
  (require srfi/1)
  (provide LVish-natpair-ivars)
  (provide downset-op)
  

  (define-LVish-language LVish-natpair-ivars
    downset-op
    my-lub
    (natural natural)
    (natural Bot)
    (Bot natural))

  ;; downset-op: Takes a pair p and returns a list of everything below
  ;; or equal to p in the lattice.

  ;; (downset-op '(2 1)) =>
  ;; '(Bot
  ;;   (Bot 0)
  ;;   (Bot 1)
  ;;   (0 Bot)
  ;;   (0 0)
  ;;   (0 1)
  ;;   (1 Bot)
  ;;   (1 0)
  ;;   (1 1)
  ;;   (2 Bot)
  ;;   (2 0)
  ;;   (2 1))
  
  (define downset-op
    (lambda (p)
      (let ([car-iota (append '(Bot) (iota (car p)) `(,(car p)))]
            [cadr-iota (append '(Bot) (iota (cadr p)) `(,(cadr p)))])
        ;; car-iota: '(Bot 0 1 2)
        ;; cadr-iota: '(Bot 0 1)
        (apply append
               (map (lambda (x)
                      (map (lambda (y)
                             (if (and (equal? x 'Bot) (equal? y 'Bot))
                                 'Bot
                                 `(,x ,y)))
                           cadr-iota))
                    car-iota)))))

  ;; my-lub: A function that takes two pairs (they might be of the
  ;; form (natural natural), (natural Bot), or (Bot natural)) and
  ;; returns a pair that is their least upper bound.

  ;; Because they're IVars, we can only safely combine two pairs if one
  ;; of them has only the car filled in, and the other has only the cadr
  ;; filled in.

  ;; assumes that a1 and a2 aren't both numbers
  (define lub-helper
    (lambda (a1 a2)
      (cond
        [(and (number? a1) (number? a2))
         ;; If we get here, something's wrong
         (error "oops!")]
        [(number? a1) a1]
        [(number? a2) a2]
        [else 'Bot])))

  (define my-lub
    (lambda (p1 p2)
      (let ([car1 (car p1)]
            [cadr1 (cadr p1)]
            [car2 (car p2)]
            [cadr2 (cadr p2)])
        (cond
          ;; nat/Bot, nat/Bot
          ;; nat/Bot, nat/nat
          ;; nat/nat, nat/Bot
          ;; nat/nat, nat/nat
          [(and (number? car1) (number? car2))
           'Top]

          ;; Bot/nat, Bot/nat
          ;; nat/nat, Bot/nat
          ;; Bot/nat, nat/nat
          [(and (number? cadr1) (number? cadr2))
           'Top]

          ;; nat/Bot, Bot/nat
          ;; Bot/nat, nat/Bot
          [else (list
                 (lub-helper car1 car2)
                 (lub-helper cadr1 cadr2))])))))

(module test-suite racket
  (require redex/reduction-semantics)
  (require (submod ".." language))
  (require "../test-helpers.rkt")

  (provide
   test-all)

  (define (test-all)
    (display "Running metafunction tests...")
    (flush-output)
    (time (meta-test-suite))

    (display "Running test suite...")
    (flush-output)
    (time (program-test-suite rr)))

  ;; Test suite

  (define (meta-test-suite)

    (test-equal
     (term (incomp ((3 Bot) (Bot 4))))
     (term #f))

    (test-equal
     (term (incomp ((2 Bot) (3 Bot) (Bot 4))))
     (term #f))

    (test-equal
     (term (incomp (Bot (4 Bot))))
     (term #f))

    (test-equal
     (term (incomp ((3 Bot) (4 Bot))))
     (term #t))

    (test-equal
     (term (incomp ((Bot 3) (Bot 4))))
     (term #t))

    (test-equal
     (term (incomp ((Bot 1) (Bot 2) (Bot 3) (Bot 4) (Bot 5))))
     (term #t))

    (test-equal
     (term (incomp ((Bot 1) (Bot 2) (Bot 3) (Bot 4) (Bot 5) (1 Bot))))
     (term #f))

    (test-equal
     (term (lookup-frozenness ((l ((2 3) #f))) l))
     (term #f))

    (test-equal
     (term (lookup-frozenness ((l ((2 3) #t))) l))
     (term #t))

    (test-equal
     (term (extend-Df () (3 3)))
     (term ((3 3))))

    (test-equal
     (term (extend-Df ((3 3) (4 4) (5 5)) (6 6)))
     (term ((6 6) (3 3) (4 4) (5 5))))

    (test-equal
     (term (contains-all-leq (1 1) (Bot (Bot 0) (Bot 1)
                                    (0 Bot) (0 0) (0 1)
                                    (1 Bot) (1 0) (1 1))))
     (term #t))

    (test-equal
     (term (contains-all-leq (1 1) ((Bot 0) (Bot 1)
                                    (0 Bot) (0 0) (0 1)
                                    (1 Bot) (1 0) (1 1))))
     (term #f))

    (test-equal
     (term (contains-all-leq (1 1) (Bot (Bot 0) (Bot 1)
                                    (0 Bot) (0 0) 
                                    (1 Bot) (1 0) (1 1))))
     (term #f))

    (test-equal
     (term (contains-all-leq (1 1) (Bot (Bot 0) (Bot 1)
                                    (0 Bot) (0 0) 
                                    (1 Bot) (1 0) (1 1)
                                    (2 Bot) (2 0) (2 1))))
     (term #f))

    (test-equal
     (term (contains-all-leq (1 1) (Bot (Bot 0) (Bot 1)
                                    (0 Bot) (0 0) (0 1)
                                    (1 Bot) (1 0) (1 1)
                                    (2 Bot) (2 0) (2 1))))
     (term #t))

    ;; For the next few tests, note that (downset (1 1)) =>
    ;; (Bot (Bot 0) (Bot 1)
    ;;  (0 Bot) (0 0) (0 1)
    ;;  (1 Bot (1 0) (1 1)))

    (test-equal
     (term (first-unhandled-d (1 1) ((Bot 0) (Bot 1))))
     (term Bot))
    
    (test-equal
     (term (first-unhandled-d (1 1) (Bot (Bot 1))))
     (term (Bot 0)))

    (test-equal
     (term (first-unhandled-d (1 1)
                              (Bot (Bot 0) (Bot 1)
                               (0 Bot) (0 0) (0 1)
                               (1 Bot) (1 0) (1 1)
                               (5 5) (6 6) (7 7))))
     (term #f))

    (test-equal
     (term (first-unhandled-d (1 1)
                              (Bot (Bot 0) (Bot 1)
                               (0 Bot) (0 0) (0 1)
                               (1 Bot) (1 0) (1 1))))
     (term #f))

    (test-equal
     (term (first-unhandled-d (1 1)
                              (Bot (Bot 0) (Bot 1)
                               (0 Bot)
                               (1 Bot) (1 0) (1 1))))
     (term (0 0)))

    (test-equal
     (term (first-unhandled-d (1 1)
                              (Bot (Bot 0) (Bot 1)
                               (0 Bot) (0 0) (0 1)
                               (1 Bot) (1 0))))

     (term (1 1)))

    (test-equal
     (term (first-unhandled-d (1 1)
                              (Bot (Bot 0) (Bot 1)
                               (0 Bot) (0 0) (0 1)
                               (1 Bot) (1 0)
                               (5 5) (6 6) (7 7))))
     (term (1 1)))

    (test-equal
     (term (first-unhandled-d (1 1)
                              ((1 Bot) (0 0) (7 7)
                               (5 5) Bot (1 0)
                               (Bot 0) (1 1) (Bot 1) 
                               (0 Bot) (6 6) (0 1))))
     (term #f))

    (test-equal
     (term (first-unhandled-d (1 1)
                              ((1 Bot) (0 0) (7 7)
                               (5 5) Bot (1 0)
                               (1 1) (Bot 1) 
                               (0 Bot) (6 6) (0 1))))
     (term (Bot 0)))

    (test-results))

  (define (program-test-suite rr)

    ;; E-Freeze
    (test-->> rr
              (term
               (() ;; empty store
                (let ((x_1 new))
                  (let ((x_2 (put x_1 (3 4))))
                    (freeze x_1 after ())))))
              (term
               (((l ((3 4) #t)))
                (3 4))))

    ;; Quasi-determinism with freezing.
    (test-->> rr
              (term
               (() ;; empty store
                (let ((x_1 new))
                  (let par
                      ((x_2 (let ((x_4 (put x_1 (3 Bot))))
                              (freeze x_1 after ())))
                       (x_3 (put x_1 (Bot 6))))
                    x_2))))
              (term
               (((l ((3 6) #t)))
                (3 6)))
              (term
               Error))

    ;; Should deterministically raise an error, since it never uses
    ;; freezing.
    (test-->> rr
              (term
               (() ;; empty store
                (let ((x_1 new))
                  (let par
                      ((x_2 (let ((x_4 (put x_1 (3 4))))
                              ;; legal, incompatible 2-element
                              ;; threshold set
                              (get x_4 ((3 4) (6 6)))))
                       (x_3 (put x_1 (6 6))))
                    x_2))))
              (term
               Error))

    ;; Should get stuck reducing, since ((3 Bot) (Bot 6)) is an
    ;; illegal threshold set.  (Actually, this isn't quite right; such
    ;; programs should be ruled out from the start somehow.)
    (test-->> rr
              (term
               (() ;; empty store
                (let ((x_1 new))
                  (let par
                      ((x_2 (get x_1 ((3 Bot) (Bot 6))))
                       (x_3 (put x_1 (6 6))))
                    x_2))))

              ;; FIXME: Is there a way to just specify "gets stuck
              ;; reducing"?  This overspecifies; I don't really care
              ;; *how* it gets stuck.
              (term
               (((l ((6 6) #f)))
                (((lambda (x_2)
                    (lambda (x_3) x_2))
                  (get l ((3 Bot) (Bot 6))))
                 ()))))

    (test-results)))

(module test-all racket
  (require (submod ".." test-suite))
  (test-all))

