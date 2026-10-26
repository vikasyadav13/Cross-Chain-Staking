# Report

## 1. Audit
## 1. Audit

### Overview

`NativeBridgeV0` allows users to lock native tokens and uses validator signatures to authorize withdrawals. The audit identified weaknesses in message authentication, replay protection, validator management, and token transfer handling.

### C-01: Incomplete Message Authentication

**Severity:** Critical

**Location:** `unlock()` — message digest calculation

**Issue:** The digest only includes the message nonce and recipient. Other security-sensitive fields, such as the amount, sender, and chain IDs, are not authenticated.

**Attack scenario:** An attacker modifies an unsigned message field, such as the withdrawal amount, while reusing valid validator signatures.

**Impact:** Unauthorized or altered withdrawals may result in loss of bridge funds.

**Fix:** Include all security-relevant message fields, the chain ID, and the destination bridge address in the digest. Validate the source and destination chain IDs before processing a withdrawal.

### H-01: Unauthorized Validator Changes

**Severity:** Critical

**Location:** `setValidators()`

**Issue:** The function does not restrict access to an administrator.

**Attack scenario:** An attacker replaces the trusted validators with attacker-controlled addresses and submits fraudulent withdrawal messages.

**Impact:** The attacker may authorize withdrawals without approval from the legitimate validators.

**Fix:** Restrict validator updates to the configured administrator. Reject zero addresses, duplicate validators, and invalid thresholds.

### H-02: Replay Across Different Signer Subsets

**Severity:** Critical

**Location:** `unlock()` — replay protection

**Issue:** The replay key is calculated using `keccak256(signatures[0])`, rather than a unique message digest.

**Attack scenario:** The same message is submitted with a different valid signer set or a different first signature, producing a different replay key.

**Impact:** The same withdrawal may be executed more than once.

**Fix:** Use the complete message digest as the replay key and mark the message as processed before transferring tokens.

### H-03: Replay Across Bridge Deployments

**Severity:** High

**Location:** `unlock()` — digest calculation

**Issue:** The digest does not bind the authorization to a specific chain and bridge deployment.

**Attack scenario:** A valid message authorization is reused on another compatible bridge deployment.

**Impact:** Unauthorized withdrawals may occur on another bridge instance.

**Fix:** Include `block.chainid` and `address(this)` in the digest.

### H-04: Reentrancy During Withdrawal

**Severity:** High

**Location:** `unlock()` — token transfer

**Issue:** The contract performs an external token transfer before updating replay-protection state.

**Attack scenario:** A malicious token re-enters `unlock()` before the message is marked as processed.

**Impact:** A withdrawal may be paid more than once.

**Fix:** Use a reentrancy guard and mark the message as processed before making external calls.

### H-05: Zero Address Accepted as Validator

**Severity:** High

**Location:** Constructor and `setValidators()`

**Issue:** The contract accepts `address(0)` as a validator.

**Attack scenario:** An invalid signature can recover to `address(0)`, which may then be treated as an authorized signer.

**Impact:** Invalid signatures may satisfy the authorization threshold.

**Fix:** Reject zero-address validators and verify that each recovered signer belongs to the active validator set.

### H-06: Duplicate Signatures Count Toward Threshold

**Severity:** High

**Location:** `unlock()` — signature verification loop

**Issue:** The contract does not ensure that each signature belongs to a distinct validator.

**Attack scenario:** A single validator's signature is submitted multiple times to meet the required threshold.

**Impact:** The intended multi-validator authorization requirement can be bypassed.

**Fix:** Enforce unique signers, for example by requiring recovered signer addresses to be strictly ascending.

### H-07: Removed Validators Remain Authorized

**Severity:** High

**Location:** `setValidators()`

**Issue:** The contract adds new validators without removing old validators from the authorization mapping.

**Attack scenario:** A validator is removed from the configured list but remains authorized in the mapping.

**Impact:** A removed validator can continue signing withdrawals.

**Fix:** Clear the old validator set and install the replacement set atomically.

### H-08: Unchecked Token Transfer Results

**Severity:** High

**Location:** `lock()` and `unlock()`

**Issue:** The contract does not check whether token transfers return `false`.

**Attack scenario:** A token transfer fails silently, but the bridge continues as if it succeeded.

**Impact:** Bridge accounting may become incorrect, and wrapped tokens may be issued without sufficient backing.

**Fix:** Use OpenZeppelin `SafeERC20` for token transfers.

### M-01: Fee-on-Transfer Accounting

**Severity:** Medium

**Location:** `lock()`

**Issue:** The contract assumes that the amount requested for transfer equals the amount received.

**Attack scenario:** A token deducts a transfer fee, causing the bridge to receive less than the requested amount.

**Impact:** The bridge may account for more backing than it actually holds.

**Fix:** Compare the bridge's token balance before and after the transfer and use the actual received amount.

### M-02: Missing Input Validation

**Severity:** Medium

**Location:** `lock()`

**Issue:** The function accepts invalid inputs, including zero amounts, zero recipients, or unsupported destination chains.

**Impact:** Users may lock funds for invalid or unusable bridge messages.

**Fix:** Validate the destination chain, recipient, and amount before transferring tokens.

### M-03: Missing Required Bridge Event

**Severity:** Medium

**Location:** `lock()`

**Issue:** The function does not emit the required `MessageSent` event.

**Impact:** Relayers may not be able to discover or process bridge messages correctly.

**Fix:** Emit `MessageSent` with the complete message and its identifier.

### M-04: Invalid Signature Recovery IDs

**Severity:** Medium

**Location:** `_splitSignature()` and signature recovery

**Issue:** Recovery IDs of `0` or `1` are not normalized to `27` or `28`.

**Impact:** Otherwise valid signatures may fail to recover the intended signer.

**Fix:** Normalize supported recovery IDs and reject invalid encodings.

### M-05: Weak Constructor Validation

**Severity:** Medium

**Location:** Constructor

**Issue:** The constructor accepts invalid addresses, duplicate validators, and impossible thresholds.

**Impact:** Incorrect configuration can undermine authorization or prevent bridge operations.

**Fix:** Validate token and administrator addresses, validator uniqueness, and threshold bounds.

### M-06: No Emergency Pause or Withdrawal Cap

**Severity:** Medium — hardening recommendation

**Location:** Bridge administration and withdrawal design

**Issue:** The bridge has no emergency pause or configured withdrawal cap.

**Impact:** If the validator quorum is compromised, losses may continue until the bridge's available reserves are exhausted.

**Fix:** Consider emergency pause controls, withdrawal limits, and monitoring if compatible with the assignment requirements.

### L-01: Empty Signature Array Causes a Panic

**Severity:** Low

**Location:** `unlock()`

**Issue:** Accessing `signatures[0]` when the array is empty causes an array-out-of-bounds panic.

**Impact:** Invalid requests fail with an unhelpful error.

**Fix:** Validate the signature count before accessing array elements.

### L-02: Unbounded Signature Processing

**Severity:** Low

**Location:** `unlock()` — signature verification loop

**Issue:** The contract does not explicitly bound the number of signatures processed.

**Impact:** Excessive signature processing can increase gas consumption.

**Fix:** Bound the accepted signature count and reject unnecessary signatures.

### I-01: Raw Digest Signature Format

**Severity:** Informational — assignment constraint

**Location:** `messageDigest()` and signature verification

**Issue:** Raw digest signing does not provide the standard EIP-191 or EIP-712 signing prefix.

**Impact:** Signatures may be reusable in another context if the same digest is interpreted by another protocol.

**Decision:** The assignment requires raw ECDSA signatures over the destination bridge's `messageDigest`. The replacement therefore preserves this format while adding chain and bridge domain separation to the digest.

### I-02: Single-Administrator Governance Risk

**Severity:** Informational — hardening recommendation

**Location:** Administrator configuration

**Issue:** A single administrator can immediately change the validator set.

**Impact:** A compromised administrator may undermine bridge authorization.

**Fix:** The replacement enforces administrator-only validator changes. Multisig governance, two-step administrator transfer, or a timelock may be considered as additional hardening.

### Test Evidence

The custom `NativeBridgeV0Test` suite contains 23 tests, all of which passed in the reported run. These tests reproduce the unsafe behaviors asserted by the test cases; they do not prove that every finding is independently exploitable in every deployment.

### Overall Assessment

`NativeBridgeV0` should not be used to secure production bridge assets in its current form. The highest-priority fixes are complete message authentication, strict validator authorization, replay protection, reentrancy protection, unique-signature verification, and safe token-transfer handling.

Emergency pause controls, withdrawal caps, and governance improvements are additional hardening recommendations rather than confirmed standalone exploits under the assignment requirements.

## 2. Improvements

The replacement bridge implementations address the principal security and correctness issues identified in `NativeBridgeV0`, while preserving the assignment's required raw ECDSA signature format.

### 2.1 Message Authentication and Domain Separation

The replacement bridges include all security-relevant message fields in the message digest: source and destination chain IDs, nonce, sender, recipient, amount, hook gas limit, and the hash of the hook data. The digest also includes the destination `block.chainid` and `address(this)`, binding each authorization to a specific destination chain and bridge deployment.

This prevents message fields from being altered without invalidating the signatures and reduces the risk of replaying an authorization across different chains or bridge deployments.

### 2.2 Validator Authorization

Validator-set updates are restricted to the configured administrator. The implementation rejects zero-address validators, duplicate validators, and invalid signature thresholds. When the validator set changes, the previous validator entries are cleared before the new set is installed.

Signature verification checks the 65-byte signature length, recovers each signer, verifies membership in the active validator set, and requires signer addresses to be strictly ascending. This prevents duplicate signers from counting multiple times toward the threshold.

### 2.3 Replay Protection and Reentrancy

Both bridges maintain a mapping of processed message digests and reject previously processed messages. A message is marked as processed before external token or hook calls, following the checks-effects-interactions pattern.

OpenZeppelin's `ReentrancyGuard` is also used on the relevant state-changing bridge entry points. These controls reduce the risk of duplicate message execution and reentrant calls during bridge operations.

### 2.4 Token Accounting and Decimal Conversion

The native bridge accounts for the actual amount received when locking tokens, rather than assuming that the requested transfer amount was received in full. This is important for fee-on-transfer tokens.

During manual testing, a request to lock 1 HBR resulted in a message amount of 0.997 HBR, reflecting the token transfer fee.

HBR uses 18 decimals, while wHBR uses 6 decimals. The bridges use a conversion factor of `1e12` and reject amounts that cannot be represented at the supported precision. Messages retain the HBR-denominated amount in 18-decimal units in both directions.

### 2.5 Hook Execution and Failure Handling

`WrappedBridge` supports optional recipient hooks. For bridge-and-stake transfers, it mints wHBR to `StakeOnArrival` and calls `onBridgeReceived()` with the message details and hook data.

If the staking attempt fails, `StakeOnArrival` catches the failure and transfers the wHBR to the designated beneficiary. If the outer hook call itself reverts, `WrappedBridge` burns the tokens minted to the hook recipient and remints them to the original message sender.

This separates staking-specific behavior from core bridge verification and provides different recovery paths for a failed staking attempt and a completely reverted hook call.

### 2.6 Testing and Validation

The Foundry test suite contains three test files with **30 passing tests, 0 failures, and 0 skipped tests**.

**1. `test/NativeBridgeV0.t.sol` — 23 tests**

Tests the original V0 implementation and reproduces its security weaknesses, including:

- Replay attacks and reuse of the same message.
- Incomplete message authentication and signature validation.
- Unauthorized validator changes and duplicate validators or signatures.
- Reentrancy during withdrawals.
- Unsafe token-transfer handling and fee-on-transfer accounting.
- Invalid inputs, missing bridge events, and unsafe threshold configuration.

These tests intentionally demonstrate vulnerable behavior in the original implementation. Passing means the tests reproduced the behavior they were designed to verify; it does not mean the behavior is secure.

**2. `test/BridgeSecurity.t.sol` — 5 tests**

Tests selected security protections in the replacement bridge contracts:

- Rejecting replayed messages on both bridges.
- Preventing non-admin users from changing validators.
- Rejecting duplicate signers.
- Completing an HBR-to-wHBR-to-HBR round trip.

**3. `test/Public.t.sol` — 2 tests**

Tests the main user-facing flows:

- `test_BridgeAndStake()` — bridge and staking flow.
- `test_RoundTrip()` — standard bridge round trip.

**Overall result:** 30 tests passed, 0 failed, and 0 skipped.

Additional manual testing on two local Anvil chains verified a standard bridge round trip, successful staking through `StakeOnArrival`, and fallback transfer to the beneficiary when staking failed. A staking withdrawal and subsequent return-bridge message were also exercised.

These results demonstrate that the tested scenarios behaved as expected. They do not constitute formal verification or guarantee that all possible vulnerabilities have been eliminated.

### 2.7 Additional Production Hardening

The following measures were considered beyond the core assignment implementation:

- **Emergency pause:** Introduce carefully governed emergency controls to restrict bridge operations during an incident.
- **Withdrawal limits:** Consider per-transaction or time-window limits to reduce potential losses following validator compromise.
- **Administrator governance:** Consider multisig administration, a timelock, or two-step administrator transfer.
- **Monitoring:** Alert on validator changes, unusual message volumes, failed hooks, and unexpected bridge balances.
- **Further assurance:** Add fuzz tests, invariant tests, adversarial hook tests, and independent security review.

These are additional production-hardening recommendations, not claims that the corresponding controls are already implemented.

## 3. Chain B Design

### 3.1 Architecture

The Chain B implementation consists of three main contracts:

- **`WrappedHarbor`:** The 6-decimal ERC-20 representation of HBR. Only the configured bridge can mint or burn tokens.
- **`WrappedBridge`:** Validates incoming messages and validator signatures, prevents replay, mints wHBR, executes optional recipient hooks, and burns wHBR to create return messages.
- **`StakeOnArrival`:** Receives wHBR from a bridge-and-stake message, attempts to deposit it into `HarborStaking` for the designated beneficiary, and transfers the tokens to that beneficiary if staking fails.

The bridge is configured with a remote chain ID, validator set, signature threshold, and administrator. `WrappedHarbor` is configured to trust `WrappedBridge` as its authorized minter and burner.

### 3.2 Bridge-and-Stake Flow

The flow begins on Chain A when the user calls `NativeBridge.lockWithHook()`, specifying Chain B as the destination, `StakeOnArrival` as the recipient, a beneficiary address in the hook data, and a nonzero hook gas limit.

1. **Lock HBR:** `NativeBridge` receives the net HBR amount and emits `MessageSent` containing the message and hook data.
2. **Collect signatures:** Relayers obtain the message and collect the required validator signatures over the destination bridge's message digest.
3. **Verify the message:** On Chain B, `WrappedBridge.mint()` validates the chain IDs, addresses, amount, precision, hook parameters, replay status, and validator signatures.
4. **Mint wHBR:** After marking the message as processed, the bridge mints the corresponding 6-decimal amount to `StakeOnArrival`.
5. **Attempt staking:** The bridge calls `onBridgeReceived()`. The hook decodes the beneficiary address and invokes its guarded `stakeFor()` helper, which temporarily approves `HarborStaking` and deposits the tokens for that beneficiary.
6. **Handle staking failure:** If the staking operation fails, the hook catches the error and transfers the wHBR to the beneficiary. `StakeAttempted` records whether staking succeeded.
7. **Return to Chain A:** A holder can call `WrappedBridge.burn()` to burn wHBR and emit a return message denominated in 18-decimal HBR units. After the message is authorized by validators, `NativeBridge.unlock()` releases HBR on Chain A.

### 3.3 Flow Diagram

```text
                 CHAIN A
             ┌────────────────┐
             │      User      │
             └───────┬────────┘
                     │ lockWithHook()
                     ▼
             ┌────────────────┐
             │  NativeBridge  │
             │ Lock HBR       │
             │ Emit Message   │
             └───────┬────────┘
                     │
              Relayer collects
             validator signatures
                     │
                     ▼
                 CHAIN B
             ┌────────────────┐
             │ WrappedBridge  │
             │ Verify message │
             │ Check replay   │
             │ Mint wHBR      │
             └───────┬────────┘
                     │
                     ▼
             ┌────────────────┐
             │ StakeOnArrival │
             │ Decode user    │
             │ Attempt stake  │
             └───────┬────────┘
                     │
                ┌────┴────┐
                │         │
             Success    Failure
                │         │
                ▼         ▼
          ┌──────────┐ ┌──────────┐
          │ Harbor   │ │Beneficiary│
          │ Staking  │ │ receives  │
          │ Records  │ │ wHBR      │
          │ the stake│ │ directly  │
          └──────────┘ └──────────┘
```

### 3.4 Hook Failure Semantics

The implementation distinguishes between a staking failure and a complete hook-call failure.

If `HarborStaking.deposit()` reverts, `StakeOnArrival` catches the error and transfers the wHBR to the beneficiary. Since the hook returns successfully, `WrappedBridge` emits `HookCallResult` with `success = true`, while `StakeAttempted` records `success = false`.

If the outer call to `onBridgeReceived()` reverts, `WrappedBridge` emits a failed hook-call result, burns the tokens minted to the hook recipient, and remints them to the original message sender. This prevents the minted tokens from remaining stranded at a recipient whose hook execution fails entirely.

### 3.5 Design Decisions and Limitations

The hook is separated from the bridge so that staking-specific logic remains independent of core message authentication and token accounting. This separation makes the bridge easier to reason about and allows the hook's behavior to be changed independently.

The staking contract and pool ID are configured at deployment. This keeps the implementation simple for the assignment but limits flexibility if the staking destination or pool needs to change.

The design relies on validator signatures to authorize cross-chain messages; it does not independently verify Chain A transactions on Chain B. Validator security, administrator governance, relayer availability, staking-pool configuration, and operational monitoring remain important considerations for production deployment.