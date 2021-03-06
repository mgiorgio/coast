#lang racket/base

(require
  "../../include/base.rkt"
  "../../baseline.rkt"
  [only-in "../../curl/base.rkt" curl/origin curl/path curl/metadata]
  "../../transport/gate.rkt"
  ;"../../uuid.rkt"
  "coastapp-utils.rkt")

(provide pilot)

;; curl pre-generated by the simulation server, this grants the pilot the authority to spawn simulations
(define/curl/inline SIM-SERVER/CURL/SPAWN
  #<<!!
SIGNATURE = #"zVMpXbsnYES0IRooE3QI4a1FpwKws-CilmEexuawFCeCKXcBpZhBHzz9vzXYqpv6nf6hYJ6_qvInhnX2YrpECg"
CURL
    id = dda12627-9e96-4efe-8d8d-8dc8896cebf6
    origin = #"RaQDnsBmoxoaCe_rkNuPJB1Q7PgSaYm17jzafmYFPSc"
    path = (service spawn)
    access/id = ingress.service.spawn
    created = "2016-06-22T16:25:22Z"
    metadata = #f

!!
  )


;; The compiled SIMULATION is transmitted from the pilot to a remote simulator island for execution.
(define SIMULATION-FACTORY
  ; Motile source follows.
  '(begin
    ; Access routines for lunar lander state tuple: <altitude fuel velocity>.
    (define (altitude/get v) (tuple/ref v 0))
    (define (fuel/get v)     (tuple/ref v 1))
    (define (velocity/get v) (tuple/ref v 2))
    
    (define (fuel/empty? state) (= (fuel/get state) 0))
    (define (touchdown? state) (= (altitude/get state) 0))
    (define (landing/soft? state)
      (<= (velocity/get state) MAX_LANDING_VELOCITY))
    (define (command/thruster? command)
      (and
        (pair? command)
        (eq? (car command) 'THRUSTER)
        (integer? (cdr command))
        (>= (cdr command) 0)))
     
    (define (state/summary state)
      (format "Altitude: ~a Fuel: ~a Velocity: ~a" 
              (round (altitude/get state))
              (round (fuel/get state))
              (round (velocity/get state))))

    ; Initial lunar lander state #(altitude fuel velocity).
    (define (INITIAL-STATE) (tuple 1000.0 750.0 70.0))
    
    (define GRAVITY 1.4)  ; Gravitational constant.
    (define MAX_LANDING_VELOCITY 5) ; Upper bound for a soft landing.
    
    ;; Given a state tuple and a thruster value
    ;; (the number of units of fuel to burn)
    ;; calculate and return a successor state tuple.
    (define (state/recalculate state thruster)
      (let
          ((altitude+ (max 0 (- (altitude/get state) (velocity/get state)))) ; New altitude.
           (fuel+ (max 0 (- (fuel/get state) thruster))) ; Remaining fuel.
           (velocity+  ; ((velocity + GRAVITY)*10 - (thruster*2)) / 10
            (max 0 (/ (- (* (+ (velocity/get state) GRAVITY) 10) (* thruster 2)) 10))))
        
        ; Check if we just ran out of fuel.
        (when (and (= fuel+ 0) (> (fuel/get state) 0))
          (display "Fuel depleted\n")      ; Issue a notice on the simulation side.
          (send state@ "FUEL DEPLETED"))  ; Warn the pilot.
        
        ; Return successor state tuple.
        (tuple altitude+ fuel+ velocity+)))
          
    ; Main loop of the lunar lander simulation.
    (define (simulation/loop state@ thruster/d)
      ; At the head of the loop we check (non-blocking) for a thruster update from the pilot.
      ; The simulation begins with the INTITIAL-STATE and a thruster setting of 0.
      (let loop ([m (duplet/try thruster/d)] [state (INITIAL-STATE)] [thruster 0])
        (cond
          ((not m) ; No thruster update was available.
           (sleep 4.0) ; Give pilot enough time to respond to state changes.
           (let* ((state+ (state/recalculate state thruster)) ; Compute successor state.
                  (summary (state/summary state+)))
             (display (format "simulation: summary ~a\n" summary))
             (send state@ summary)  ; Transmit fresh state summary to pilot.
             (if (touchdown? state+)
                 ; Was the landing soft or hard?
                 ; In either case the simulation loop terminates.
                 (if (landing/soft? state)
                     (send state@ "You've landed!")
                     (send state@ "You've crashed!"))
                 ; Otherwise lander is still descending.
                 ; Loop with the updated state and with zero thruster
                 ; if the fuel tank is empty.
                 (loop
                  (duplet/try thruster/d)
                  state+
                  (if (fuel/empty? state+) 0 thruster)))))
          (else ; Command received from the pilot.
           (let ((command (murmur/payload m))) ; Extract the command.
             (if (command/thruster? command)
                 ; Legal thruster command.
                 (cond
                   ((fuel/empty? state)
                    ; Fuel is exhausted. Warn pilot.
                    (send state@ "FUEL DEPLETED")
                    ; Loop to continue calculating state.
                    ; If pilot is skilled (or lucky) she'll have a soft landing.
                    (loop (duplet/try thruster/d) state 0))
                   (else
                    ; Some fuel remains.
                    (let ((thruster+ (cdr command)))
                      (display (format "simulation: thruster ~a\n" thruster+))
                      (loop (duplet/try thruster/d) state thruster+))))
                 
                 ; Unknown command. Just continue simulation.
                 (begin
                   (display (format "simulation: unknown command ~a\n" command))
                   (loop (duplet/try thruster/d) state thruster))))))))
  
    
     ; Higher order function that returns a lunar lander simulator as a thunk.
     ; state@: CURL from pilot for state updates from simulator.
     ; boot@: Promise CURL from pilot to obtain simulation CURL that pilot uses to
     ;       transmit thruster updates.
    (define (simulation/new state@ boot@)
      (lambda()
        (display "simulation: start\n")
        (display (format "simulation: state@ path ~a\n" (curl/path state@)))
        (display (format "simulation: boot@ path ~a\n" (curl/path boot@)))
        (let ((thruster/d (islet/curl/new '(commands) GATE/ALWAYS #f 'INTER)))
          (display (format "simulation: thruster/d ~a\n" thruster/d))
          (send boot@ (duplet/resolver thruster/d))
          (display "simulation: transmitted resolver of thruster/d\n")
          (sleep 1.0) ; Give pilot time to receive thruster CURL.
          
          ; Enter simulation loop and don't return until lander
          ; either lands safely or crashes.
          (simulation/loop state@ thruster/d)
          
          (display "simulation: game over\n")
          (display "simulation: exiting\n"))))
  
    simulation/new))


;; Input reader service for the pilot.
(define (thruster/read thruster@)
  (display "pilot: Running input reader for thruster values\n")
  (let loop ([value (read)]) ; Prompt pilot for thruster update.
    ; Send thrust value to executing simulation.
    (send thruster@ (cons 'THRUSTER value))
    (loop (read))))

; Create a nanoservice dedicated to reading pilot input
; for the thruster.
(define (pilot/input thruster@)
  ; First create a new islet.
  (let ([x (islet/new
            (this/island)
            'pilot.input
            TRUST/MODERATE
            environ/null environ/null)])
    (islet/jumpstart x (lambda () (thruster/read thruster@)))))

;; Code for a pilot island.
;; server/u - CURL for spawn service on Sim Server.
(define (pilot/boot server/u)
  (display "pilot: booting ...\n")
  
  (display "pilot: waiting for simulator ...\n")
  (island/enter/wait (curl/origin server/u))
  (display "pilot: saw simulator\n")
  
  ; state/d: duplet (CURL/egress pair) on which pilot will receive state updates.
  ; thruster/p: promise to be resolved by simulation. Resolution will be a CURL on
  ; which pilot will send thruster values.
  ; state@: CURL on which simulator will transmit state updates.
  ; 
  (let* ([state/d (islet/curl/new '(state notify) GATE/ALWAYS #f INTER)]
         [thruster/p (promise/new)]
         [state@ (duplet/resolver state/d)]
         [boot@  (promise/resolver thruster/p)]
         [factory (island/compile SIMULATION-FACTORY)]
         [THUNK/SIMULATION
          (motile/call factory BASELINE state@ boot@)])
    
    (display "pilot: sending simulation thunk to simulator ...\n")
    (send server/u THUNK/SIMULATION)
    (display "pilot: simulation thunk sent\n") 
    
    ; Listen for curl on which to send thruster updates to simulation.
    (display "pilot: waiting for thruster curl from simulation\n")
    (let* ([m (promise/block thruster/p)]  ; Listen for the CURL.
           [thruster@ (murmur/payload m)]) ; Extract CURL for thruster updates.
      (display "pilot: received thruster CURL from simulation\n")
      (pilot/input thruster@) ; Start dedicated islet for reading pilot input.
      
      ; Listen for lunar lander state events.
      (let loop ([m (duplet/block state/d)])
        (let ([state+ (murmur/payload m)]) ; Extract the murmur's payload.
          (display state+)(newline))
        (loop (duplet/block state/d))))))

; Construct an in-memory CURL instance of the predefined CURL for sim-server.
(define sim-server/curl/spawn (curl/zpl/safe-to-curl SIM-SERVER/CURL/SPAWN KEYSTORE))

; fire up the pilot island
(define pilot
  (example/island/new
   'pilot          ; Name of pilot island.
   "pilot_secret"  ; Filename of island certificate.
   (lambda ()      ; Bootstrap thunk for island.
     (pilot/boot sim-server/curl/spawn))))

(island/log/level/set 'warning)


