# Error codes

The database raises custom SQLSTATEs (class `LD`) so the API can map errors without
parsing messages. PostgreSQL's own codes are listed where the API must also handle them.

| SQLSTATE | Meaning                                                                                      | HTTP  |
| -------- | -------------------------------------------------------------------------------------------- | ----- |
| LD001    | Transaction unbalanced (debits <> credits)                                                   | 422   |
| LD002    | Fewer than 2 entries                                                                         | 422   |
| LD003    | Attempt to modify immutable ledger rows                                                      | 500   |
| LD004    | Account has no balance row (internal fault)                                                  | 500   |
| LD010    | Idempotency key reused with a different request                                              | 422   |
| LD011    | Request with this key is still in progress                                                   | 409   |
| LD020    | Account not found                                                                            | 404   |
| LD021    | Account not active (frozen or closed)                                                        | 422   |
| LD022    | Insufficient funds (no-overdraft rule)                                                       | 422   |
| LD030    | Malformed or invalid request                                                                 | 400   |
| LD031    | Entry currency does not match account currency                                               | 422   |
| LD040    | Transaction to reverse not found                                                             | 404   |
| LD041    | Transaction already reversed                                                                 | 409   |
| LD042    | A reversal cannot be reversed                                                                | 422   |
| 40001    | Serialization failure: retry (Phase 5)                                                       | retry |
| 40P01    | Deadlock detected: retry (Phase 5)                                                           | retry |
| 23505    | Unique violation on `transactions_idempotency_key_key` (key reused after its record expired) | 409   |
| LD043    | Invoice transactions cannot be reversed directly (use void_invoice)                          | 422   |
| LD050    | Payment exceeds the invoice's remaining balance                                              | 422   |
| LD051    | Invoice accounts have the wrong types or do not exist                                        | 422   |
| LD052    | Invoice not found                                                                            | 404   |
| LD053    | Invoice state does not allow this action                                                     | 409   |
| LD054    | Illegal invoice change (immutable field or status transition)                                | 500   |
| LD056    | Invoice total differs from the sum of its lines                                              | 500   |
