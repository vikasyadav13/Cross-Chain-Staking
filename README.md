How to run and test

Here is the complete step-by-step record of our manual testing of the Harbor Bridge from start to finish, including Remix setup, both bridge directions, commands, signatures, transaction results, and manual balanceOf checks.
You can also use this as a reference when writing docs/REPORT.md.
Harbor Bridge — Manual Testing Report
1. Testing environment and setup
We tested the bridge locally using Foundry, two Anvil chains, and Remix.
1.1 Start both Anvil chains
Open two terminal windows and keep both processes running.
Terminal 1 — Chain A
anvil --chain-id 8453200012 --port 8545 --allow-origin "*"
Terminal 2 — Chain B
anvil --chain-id 1002 --port 8546 --allow-origin "*"
1.2 Connect Remix to each chain
Setting
Chain A
Chain B
Chain ID
8453200012
1002
RPC URL
http://127.0.0.1:8545
http://127.0.0.1:8546
Native token
HBR
wHBR
Token decimals
18
6

1.3 Test accounts
Role
Address
Account 1 / Validator 1 / admin
0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Account 2 / Validator 2 / recipient
0x70997970C51812dc3A010C7d01b50e0d17dc79C8

These are public test accounts and private keys supplied by the local Anvil development environment. Do not use them to manage real funds.
1.4 Deployed contract addresses
Contract
Chain
Address
HarborToken
A
0x5FbDB2315678afecb367f032d93F642f64180aa3
NativeBridge
A
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
WrappedHarbor
B
0x5FbDB2315678afecb367f032d93F642f64180aa3
WrappedBridge
B
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

The addresses are the same across chains because each Anvil instance uses deterministic local deployment addresses. They represent separate contract deployments on the two chains.
We also called WrappedHarbor.setBridge(...) on Chain B and confirmed the WrappedHarbor token was configured with the WrappedBridge address.
2. Test A — HBR approval on Chain A
Goal: Allow NativeBridge to transfer 100 HBR from Account 1.
In Remix:
Select Chain A (8453200012).
Open HarborToken at 0x5FbDB2315678afecb367f032d93F642f64180aa3.
Select approve(address,uint256).
Enter the NativeBridge address and the amount below.
Parameter
Value
Spender
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
Amount
100000000000000000000

Because HBR has 18 decimals, this amount is 1001018 base units, or 100 HBR.
The approval transaction succeeded.
3. Test B — Lock 100 HBR on Chain A
Goal: Lock HBR and create a cross-chain message for minting wHBR on Chain B.
In Remix, on Chain A, open NativeBridge and call:
lock(uint256 dstChainId, address recipient, uint256 amount)
Inputs:
Parameter
Value
Destination chain ID
1002
Recipient
0x70997970C51812dc3A010C7d01b50e0d17dc79C8
Amount
100000000000000000000

Transaction result
Status: Successful
Transaction hash: 0xbb3a7c6ec4c1a883aba3cae87e33078d925fb4e430083084afc1736cb6cc07a4
Block: 7 on Chain A
The HarborToken charges a 0.3% transfer fee. Consequently, the bridge received 99.7 HBR rather than the full 100 HBR.
MessageSent event
Field
Value
srcChainId
8453200012
dstChainId
1002
nonce
1
sender
0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
recipient
0x70997970C51812dc3A010C7d01b50e0d17dc79C8
amount
99700000000000000000
hookGasLimit
0
hookData
0x
messageId
0x73f5e0621241b5423c2024a96868149a202a6a0136561a16a3acd1822431b486

Manual balance checks
The Account 1 HBR balance before locking was:
1000000000000000000000000000
After locking, it was:
999999900300000000000000000
The NativeBridge HBR balance was:
99700000000000000000
These values confirm the bridge received 99.7 HBR after the 0.3 HBR fee.
4. Test C — Calculate the destination message digest
Goal: Calculate the digest on Chain B that the validators must sign to authorize minting.
In Remix:
Switch to Chain B (1002).
Open WrappedBridge at 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512.
Expand messageDigest.
Enter the entire Message as one tuple.
We initially tried entering the tuple as separate arguments and got a Remix encoding error:
too many arguments: types/values length mismatch
The working format was a JSON array in the single tuple field:
[
  8453200012,
  1002,
  1,
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "99700000000000000000",
  0,
  "0x"
]
The digest returned was:
0x6d4a209d9ed39254d21befdc8e813efdb934df079e4abe87320fc0db40696ddd
5. Test D — Sign the message with two validators
Goal: Produce two validator signatures to meet the bridge’s signature threshold of 2.
We signed the raw digest using Foundry's cast wallet sign --no-hash command. This avoids adding the Ethereum signed-message prefix.
Validator 1
cast wallet sign --no-hash \
  0x6d4a209d9ed39254d21befdc8e813efdb934df079e4abe87320fc0db40696ddd \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
Validator 2
cast wallet sign --no-hash \
  0x6d4a209d9ed39254d21befdc8e813efdb934df079e4abe87320fc0db40696ddd \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
Both signatures were generated successfully.
Signature ordering: The bridge requires signatures sorted by signer address in ascending order. Therefore, Validator 2 (0x7099...) was placed first and Validator 1 (0xf39F...) second.
6. Test E — Mint wHBR on Chain B
Goal: Verify the signatures and mint the corresponding wHBR to Account 2.
We updated src/script/EncodeMint.s.sol with the message, signatures, and IWrappedBridge.mint(...) call.
Then ran:
forge build
The build succeeded.
Next, we broadcast the mint script to Chain B:
forge script src/script/EncodeMint.s.sol:EncodeMint \
  --rpc-url http://127.0.0.1:8546 \
  --broadcast
Transaction result
Status: Successful
Transaction hash: 0x1eb7023283baa5f1fcc48bb2aa9489463840b797f050b4e8cb930a2340a81273
Block: 8 on Chain B
Function: WrappedBridge.mint
Manual balance check
In Remix, we called:
WrappedHarbor.balanceOf(Account2)
Result:
99700000
WrappedHarbor has 6 decimals, so:
99700000 base units = 99.7 wHBR
The mint was confirmed by the manual balance check.
7. Test F — Approve wHBR for burning on Chain B
Goal: Allow WrappedBridge to burn Account 2’s wHBR.
We opened WrappedHarbor on Chain B and called:
approve(address spender, uint256 value)
Inputs:
Parameter
Value
Spender
0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
Amount
99700000

The first approval was accidentally sent from Account 1, which had zero wHBR. We checked balanceOf(Account1) and confirmed it returned zero.
We then switched Remix to Account 2 and submitted the approval again.
Correct approval result
Status: Successful
Transaction hash: 0xe9f52c2d0f4c39b73217a4e2ea6505cbe0c5dd0ccf509c61ff239aa57752a7d5
Block: 10 on Chain B
The Approval event confirmed:
Owner: Account 2
Spender: WrappedBridge
Allowance: 99700000
8. Test G — Burn wHBR on Chain B
Goal: Burn the 99.7 wHBR and create a message to unlock HBR on Chain A.
In Remix, with Account 2 selected on Chain B, we called:
burn(uint256 dstChainId, address recipient, uint256 amount)
Inputs:
Parameter
Value
Destination chain ID
8453200012
Recipient
0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Amount
99700000

Transaction result
Status: Successful
Transaction hash: 0x811abfda00fa78245e3da37054e7ec9a9edc27c490d2a95123c72e3a4aa85f06
Block: 11 on Chain B
The Transfer event confirmed 99700000 wHBR was burned.
Manual balance check
We called:
WrappedHarbor.balanceOf(Account2)
Result:
0
This confirmed Account 2 no longer held any wHBR.
MessageSent event for the return transfer
Field
Value
srcChainId
1002
dstChainId
8453200012
nonce
1
sender
0x70997970C51812dc3A010C7d01b50e0d17dc79C8
recipient
0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
amount
99700000000000000000
hookGasLimit
0
hookData
0x
messageId
0x500e871d6f11f28f3598a68f42a5e4a42b9af3fc61efc75ae6e540335e44b466

The amount is represented in 18-decimal HBR base units in the message, even though the burned wHBR used 6 decimals.
9. Test H — Calculate the return message digest on Chain A
Goal: Calculate the digest for the unlock message on Chain A.
We first recorded Account 1’s HBR balance before unlock:
999999900300000000000000000
Then, in Remix on Chain A, we opened NativeBridge and called messageDigest using the return message.
The first tuple input attempt failed with a Remix encoding error. We then entered the tuple as a JSON array in the single tuple field:
[
  1002,
  8453200012,
  1,
  "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  "99700000000000000000",
  0,
  "0x"
]
The digest returned was:
0x2c6ccad308de2411593ce0a7d39b783fef11d037b846d848fc3dc369477d6ab9
Note: The transaction display showed WrappedBridge.messageDigest in its details even though we intended to call NativeBridge. The call returned the digest shown above, and the subsequent unlock transaction succeeded. For the report, it is safest to record the actual contract selected in Remix and the successful unlock transaction rather than assume the UI label alone proves which contract was queried.
10. Test I — Sign the return message
Goal: Obtain two validator signatures for the return message digest.
Validator 1 signature
cast wallet sign --no-hash \
  0x2c6ccad308de2411593ce0a7d39b783fef11d037b846d848fc3dc369477d6ab9 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
Signature generated:
0xd50211f8541a0d135003c7d420297c0f33baf26a3c9b20c918807179fb53c825067c2599e8edc146f1d67816838622b20f2c227037a31d27b4a4b563389338f01c
Validator 2 signature
cast wallet sign --no-hash \
  0x2c6ccad308de2411593ce0a7d39b783fef11d037b846d848fc3dc369477d6ab9 \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
Signature generated:
0x2c09e44c1c8cb89142ffa418448d83f04075b3380d1714b4f6bd6c1ff66b3a9a0f7eba80ed6002df55334dab3f0852e9d7c72491af3c26e0c6975f326dd1a0121b
As before, the signatures were placed in ascending signer-address order:
Validator 2 (0x7099...)
Validator 1 (0xf39F...)
11. Test J — Unlock HBR on Chain A
Goal: Verify the validator signatures and unlock the HBR on Chain A.
We updated the complete src/script/EncodeMint.s.sol file to use:
The return message from the burn event
The two return-message signatures
INativeBridge.unlock(message, signatures)
Then we ran forge build, which succeeded.
We broadcast the script to Chain A:
forge script src/script/EncodeMint.s.sol:EncodeMint \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
Transaction result
Status: Successful
Transaction hash: 0x7fce30d762338d63890ddd63c4650e496196d5a46f4fb6c8391e96cc869fe313
Block: 8 on Chain A
Function: NativeBridge.unlock
The script completed successfully.
12. Test K — Verify the final HBR balance manually
Goal: Confirm the unlocked HBR was received.
In Remix on Chain A, we opened HarborToken and called:
balanceOf(Account1)
Balance before the original lock
1000000000000000000000000000
Balance after the original lock
999999900300000000000000000
Balance after the return unlock
1000000000000000000000000000
The final balance exactly matches the original balance.
Why the balance returned to the starting value
The unlock amount was 99.7 HBR. The HarborToken charges a 0.3% transfer fee, and Account 1 is both the recipient and the fee collector. As a result, Account 1 receives both the net transfer amount and the fee.
The total increase in Account 1’s balance was:
99700000000000000000
That equals 99.7 HBR, returning the balance to the original amount.
13. Summary of manual test results
Test
Expected behavior
Actual result
Status
Approve HBR
NativeBridge can transfer 100 HBR
Approval succeeded
Pass
Lock HBR
Lock 100 HBR and emit a message
Bridge received 99.7 HBR after fee
Pass
Calculate A → B digest
Produce a digest for the mint message
Digest returned
Pass
Validator signatures A → B
Two validators authorize mint
Two signatures generated
Pass
Mint wHBR
Mint 99.7 wHBR to Account 2
balanceOf returned 99700000
Pass
Approve wHBR
WrappedBridge can burn 99.7 wHBR
Approval from Account 2 succeeded
Pass
Burn wHBR
Burn 99.7 wHBR and emit return message
Burn succeeded
Pass
Verify wHBR burn
Account 2 balance becomes zero
balanceOf returned 0
Pass
Calculate B → A digest
Produce a digest for the unlock message
Digest returned
Pass
Validator signatures B → A
Two validators authorize unlock
Two signatures generated
Pass
Unlock HBR
Release HBR to Account 1
Unlock succeeded
Pass
Final HBR balance
Return to starting balance
Final balance matched starting balance
Pass

Overall result: The manual round trip from Chain A to Chain B and back to Chain A completed successfully. We verified the mint, burn, and final unlock using successful transactions and manual token balance checks.

How to test StakeOnArrival
Step 1 — Confirm both Anvil chains are running
Open two terminal windows.
Terminal 1 — Chain A
anvil --chain-id 8453200012 --port 8545
Terminal 2 — Chain B
anvil --chain-id 1002 --port 8546
Keep both terminals open. These commands start fresh local chains, so if your existing Anvil chains are already running with your deployed contracts, do not restart them—you would lose their in-memory state.
Step 2 — Confirm your Remix networks
In Remix, select Deploy & Run Transactions.
Chain A: http://127.0.0.1:8545, chain ID 8453200012
Chain B: http://127.0.0.1:8546, chain ID 1002
Make sure you select the correct network before interacting with each contract.
Step 3 — Check the Chain B staking setup
On Chain B, you should already have these deployed:
WrappedHarbor
WrappedBridge
HarborStaking
StakeOnArrival
Verify the following:
WrappedHarbor.bridge() returns your deployed WrappedBridge address.
HarborStaking.poolLength() is at least 1.
StakeOnArrival was deployed with the correct WrappedBridge, WrappedHarbor, HarborStaking, and pool ID 0.
HarborStaking.isOperator(StakeOnArrivalAddress) returns true.
The staking team must authorize the hook contract as an operator for staking on behalf of beneficiaries.
Step 4 — Prepare the bridge-and-stake transaction
On Chain A, select HarborToken and call:
approve(NativeBridgeAddress, 1000000000000000000)
This approves 1 HBR.
Then call NativeBridge.lockWithHook using:
Destination chain ID: 1002
Recipient: your deployed StakeOnArrival address
Amount: 1000000000000000000 (1 HBR)
Hook gas limit: 300000
Hook data: ABI-encoded beneficiary address
For your existing test setup, the beneficiary is Account 2:
0x70997970C51812dc3A010C7d01e17dc79C8
Important: Use the exact Account 2 address from your Anvil account list and encode it as a 32-byte ABI word. The example above is illustrative; verify the address before submitting.
Step 5 — Submit the message on Chain B
After locking, read the emitted MessageSent event on Chain A. Obtain the message fields and message ID.
The validators must sign the destination bridge's messageDigest(message). Submit the message and the required signatures to WrappedBridge.mint.
For your setup, signatures must be in ascending signer-address order. The mint should send wHBR to StakeOnArrival, which then attempts to stake for the beneficiary.
Step 6 — Verify successful staking
On Chain B, call:
HarborStaking.userInfo(0, beneficiaryAddress)
Check that the user's staked amount has increased.
Also check the StakeAttempted event emitted by StakeOnArrival; its success field should be true.
Step 7 — Test the fallback
To test the fallback, temporarily disable the hook's operator permission using the staking admin account:
HarborStaking.setOperator(StakeOnArrivalAddress, false)
Repeat the bridge-and-stake flow with a new message and nonce. The staking attempt should fail, and StakeOnArrival should transfer the received wHBR to the beneficiary instead.
Verify that StakeAttempted reports failure and the beneficiary's wHBR balance increases.
Restore the permission afterward:
HarborStaking.setOperator(StakeOnArrivalAddress, true)
Step 8 — Withdraw and bridge back
If the beneficiary successfully staked the tokens, wait until the staking lock period expires, then call:
HarborStaking.withdraw(0, amount, beneficiaryAddress)
Once the beneficiary holds wHBR, approve WrappedBridge and call burn with the Chain A destination and recipient.
Finally, submit the signed return message to NativeBridge.unlock on Chain A. Confirm that the HBR balance increases and that the message is marked processed.

