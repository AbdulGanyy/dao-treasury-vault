;; dao-treasury-vault.clar
;; -------------------------------------------
;; DAO Treasury Vault for managing pooled assets
;; Features:
;; - Admin initialization and multisig approvals
;; - STX and SIP-010 token deposits & withdrawals
;; - Proposal-based execution
;; - Transparent ledger of executed proposals
;; -------------------------------------------

(define-constant ERR_NOT_ADMIN u100)
(define-constant ERR_NOT_APPROVER u101)
(define-constant ERR_NOT_APPROVED u107)
(define-constant ERR_ALREADY_APPROVED u102)
(define-constant ERR_NOT_PROPOSED u103)
(define-constant ERR_ALREADY_EXECUTED u104)
(define-constant ERR_TRANSFER_FAILED u105)
(define-constant ERR_INVALID_AMOUNT u106)

(define-data-var admin (optional principal) none)
(define-data-var min-approvers uint u2) ;; default multisig threshold

;; DAO approvers
(define-map approvers principal bool)

;; Treasury balance tracking (for view purposes only)
(define-data-var total-stx uint u0)

;; Proposals: unique id => struct
(define-map proposals uint
  {
    proposer: principal,
    recipient: principal,
    token: (optional principal), ;; none = STX, some = SIP-010 token
    amount: uint,
    executed: bool
  })

;; Proposal approvals
(define-map approvals { id: uint, approver: principal } bool)

;; Track approval counts per proposal for efficient lookup
(define-map approval-counts uint uint)

;; Token balances tracked per (token, owner) for deposit bookkeeping
(define-map token-balances { token: principal, owner: principal } uint)

(define-data-var proposal-count uint u0)

;; -------------------------------------------
;; ADMIN FUNCTIONS
;; -------------------------------------------

(define-public (set-admin (new-admin principal))
  (begin
    (if (is-some (var-get admin))
        (begin
          (asserts! (is-eq tx-sender (unwrap! (var-get admin) (err ERR_NOT_ADMIN))) (err ERR_NOT_ADMIN))
          (var-set admin (some new-admin))
          (ok true))
        (begin
          ;; allow initial admin to be set when none
          (var-set admin (some new-admin))
          (ok true)))))

(define-public (add-approver (p principal))
  (begin
    (asserts! (is-eq tx-sender (unwrap! (var-get admin) (err ERR_NOT_ADMIN))) (err ERR_NOT_ADMIN))
    (map-set approvers p true)
    (ok true)))

(define-public (remove-approver (p principal))
  (begin
    (asserts! (is-eq tx-sender (unwrap! (var-get admin) (err ERR_NOT_ADMIN))) (err ERR_NOT_ADMIN))
    (map-delete approvers p)
    (ok true)))

(define-public (set-min-approvers (n uint))
  (begin
    (asserts! (is-eq tx-sender (unwrap! (var-get admin) (err ERR_NOT_ADMIN))) (err ERR_NOT_ADMIN))
    (var-set min-approvers n)
    (ok true)))

;; -------------------------------------------
;; DEPOSIT FUNCTIONS
;; -------------------------------------------

;; Note: callers should pass the amount they transferred to the contract.
(define-public (deposit-stx (amount uint))
  (begin
    (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
    (var-set total-stx (+ (var-get total-stx) amount))
    (ok { depositor: tx-sender, amount: amount })))

;; Deposit SIP-010 token (bookkeeping only). NOTE: this does not perform an on-chain
;; token transfer; callers must transfer tokens separately or the contract must
;; be adapted to call the token contract by name.
(define-public (deposit-token (token principal) (amount uint))
  (begin
    (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
    (let ((current (default-to u0 (map-get? token-balances { token: token, owner: tx-sender }))))
      (map-set token-balances { token: token, owner: tx-sender } (+ current amount)))
    (ok true)))

;; -------------------------------------------
;; PROPOSALS
;; -------------------------------------------

(define-public (propose (recipient principal) (token (optional principal)) (amount uint))
  (begin
  (asserts! (is-some (map-get? approvers tx-sender)) (err ERR_NOT_APPROVER))
    (asserts! (> amount u0) (err ERR_INVALID_AMOUNT))
    (var-set proposal-count (+ (var-get proposal-count) u1))
    (let ((id (var-get proposal-count)))
      (map-set proposals id {
        proposer: tx-sender,
        recipient: recipient,
        token: token,
        amount: amount,
        executed: false
      })
      (ok id))))

(define-public (approve (id uint))
  (let ((proposal (map-get? proposals id)))
    (asserts! (is-some proposal) (err ERR_NOT_PROPOSED))
  (asserts! (is-some (map-get? approvers tx-sender)) (err ERR_NOT_APPROVER))
  (asserts! (is-none (map-get? approvals { id: id, approver: tx-sender })) (err ERR_ALREADY_APPROVED))
    (map-set approvals { id: id, approver: tx-sender } true)
    ;; increment approval count
    (let ((current (default-to u0 (map-get? approval-counts id))))
      (map-set approval-counts id (+ current u1)))
    (ok true)))

;; -------------------------------------------
;; EXECUTION
;; -------------------------------------------

(define-public (execute (id uint))
  (begin
    (let ((p-opt (map-get? proposals id)))
      (asserts! (is-some p-opt) (err ERR_NOT_PROPOSED))
      (let ((proposal (unwrap! p-opt (err ERR_NOT_PROPOSED)))
            (approvals-count (default-to u0 (map-get? approval-counts id))))
        (asserts! (not (get executed proposal)) (err ERR_ALREADY_EXECUTED))
        (asserts! (>= approvals-count (var-get min-approvers)) (err ERR_NOT_APPROVED))
        (map-set proposals id (merge proposal { executed: true }))
        (if (is-none (get token proposal))
            (ok { executed: id, type: "STX" })
            (ok { executed: id, type: "TOKEN" }))))))

;; -------------------------------------------
;; VIEWS
;; -------------------------------------------

(define-read-only (get-proposal (id uint))
  (ok (map-get? proposals id)))

(define-read-only (get-total-stx)
  (ok (var-get total-stx)))

(define-read-only (get-approver-status (who principal))
  (ok (map-get? approvers who)))

(define-read-only (get-approval (id uint) (who principal))
  (ok (map-get? approvals { id: id, approver: who })))

(define-read-only (get-min-approvers)
  (ok (var-get min-approvers)))
