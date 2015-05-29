#lang racket/base

(require
  "../../baseline.rkt"
  "../../persistent/environ.rkt"
  "./robot-server-comm.rkt"
  "../../promise.rkt"
  "../../murmur.rkt"
  "../../send.rkt"
  "../../transport/gate.rkt"
  "../../transport/access.rkt"
  "../../islet.rkt"
  "../../curl/base.rkt"
  "../../spawn.rkt")

(provide
 ROBOT/SERVER/ENV)

;; Still incomplete: time, date, gates.
(define ROBOT/SERVER/ENV
  (pairs-to-environ
   BASELINE
   (list
    ; Hack for now.
    (define/global/1 'display display) ; HACK, HACK, HACK.f
    (define/global/0 'robot/get-curl/market-server robot/get-curl/market-server)
    (define/global/0 'robot/get-curl/risk-server robot/get-curl/risk-server)
    (define/global/0 'robot/get-curl/order-router robot/get-curl/order-router)
    (define/global/1 'duplet/resolver duplet/resolver)
    (define/global/1 'duplet/block duplet/block)
    (define/global/1 'murmur/payload murmur/payload)
    (define/global/N 'islet/curl/new islet/curl/new)
    (define/global/0 'this/islet/nickname this/islet/nickname)
    (cons 'GATE/ALWAYS GATE/ALWAYS)
    (cons 'INTRA INTRA)
    (define/global/2 'send send)
    )))