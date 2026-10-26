
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";

import {Message, IHarborBridge} from "../src/interfaces/IHarborBridge.sol";
import {NativeBridge} from "../src/NativeBridge.sol";
import {WrappedBridge} from "../src/WrappedBridge.sol";
import {HarborToken} from "../src/token/HarborToken.sol";
import {WrappedHarbor} from "../src/token/WrappedHarbor.sol";

contract BridgeSecurityTest is Test {
    uint256 constant CHAIN_A = 8453200012;
    uint256 constant CHAIN_B = 1002;
    uint256 constant THRESHOLD = 2;

    address admin = address(0xAD);
    address alice = address(0xA11CE);

    HarborToken token;
    WrappedHarbor wrappedToken;
    NativeBridge nativeBridge;
    WrappedBridge wrappedBridge;

    uint256[3] validatorKeys;
    address[3] validators;

    function setUp() public {
        _createValidators();

        vm.chainId(CHAIN_A);
        token = new HarborToken(admin, admin);
        nativeBridge = new NativeBridge(
            address(token),
            CHAIN_B,
            _validatorAddresses(),
            THRESHOLD,
            admin
        );

        vm.chainId(CHAIN_B);
        wrappedToken = new WrappedHarbor(admin);
        wrappedBridge = new WrappedBridge(
            address(wrappedToken),
            CHAIN_A,
            _validatorAddresses(),
            THRESHOLD,
            admin
        );

        vm.prank(admin);
        wrappedToken.setBridge(address(wrappedBridge));

       vm.chainId(CHAIN_A);

vm.prank(admin);
token.transfer(alice, 1000 ether);

vm.prank(alice);
token.approve(address(nativeBridge), type(uint256).max);
    }

    function test_RoundTrip_HBRToWrappedAndBack() public {
        uint256 aliceStartingBalance = token.balanceOf(alice);

        // 1. Alice locks HBR on Chain A.
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.recordLogs();
        nativeBridge.lock(CHAIN_B, alice, 100 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Message memory outbound = _messageFromLogs(logs);

        assertEq(outbound.srcChainId, CHAIN_A, "wrong source chain");
        assertEq(outbound.dstChainId, CHAIN_B, "wrong destination chain");
        assertEq(outbound.sender, alice, "wrong sender");
        assertEq(outbound.recipient, alice, "wrong recipient");
        assertGt(outbound.amount, 0, "locked amount is zero");

        // HBR has a transfer fee, so the bridge receives less than 100 HBR.
        assertLt(outbound.amount, 100 ether, "expected transfer fee");
        assertEq(
            token.balanceOf(address(nativeBridge)),
            outbound.amount,
            "bridge balance should match received amount"
        );

        // 2. Validators sign the message for the destination bridge.
        vm.chainId(CHAIN_B);
        bytes[] memory mintSignatures = _sign(outbound, wrappedBridge);

        // 3. Wrapped Bridge mints wHBR to Alice.
        wrappedBridge.mint(outbound, mintSignatures);

        uint256 wrappedAmount = outbound.amount / 1e12;
        assertEq(
            wrappedToken.balanceOf(alice),
            wrappedAmount,
            "Alice should receive wHBR"
        );

        // 4. Alice burns wHBR to return to Chain A.
        vm.chainId(CHAIN_B);
        vm.prank(alice);
        vm.recordLogs();
        wrappedBridge.burn(CHAIN_A, alice, wrappedAmount);

        logs = vm.getRecordedLogs();
        Message memory returnMessage = _messageFromLogs(logs);

        assertEq(returnMessage.srcChainId, CHAIN_B, "wrong return source");
        assertEq(returnMessage.dstChainId, CHAIN_A, "wrong return destination");
        assertEq(returnMessage.sender, alice, "wrong return sender");
        assertEq(returnMessage.recipient, alice, "wrong return recipient");
        assertEq(returnMessage.amount, outbound.amount, "return amount mismatch");
        assertEq(
            wrappedToken.balanceOf(alice),
            0,
            "wHBR should be burned"
        );

        // 5. Validators sign the return message for the Native Bridge.
        vm.chainId(CHAIN_A);
        bytes[] memory unlockSignatures = _sign(returnMessage, nativeBridge);

        // 6. Native Bridge unlocks HBR to Alice.
        nativeBridge.unlock(returnMessage, unlockSignatures);

        assertGt(
            token.balanceOf(alice),
            aliceStartingBalance - 100 ether,
            "Alice should recover HBR, less applicable transfer fees"
        );
        assertEq(
            nativeBridge.processedMessages(
                nativeBridge.messageDigest(returnMessage)
            ),
            true,
            "return message should be marked processed"
        );
    }

    function test_WrappedBridgeRejectsReplay() public {
        // Create a legitimate A -> B message.
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.recordLogs();
        nativeBridge.lock(CHAIN_B, alice, 10 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Message memory message = _messageFromLogs(logs);

        // Mint once on Chain B.
        vm.chainId(CHAIN_B);
        bytes[] memory signatures = _sign(message, wrappedBridge);
        wrappedBridge.mint(message, signatures);

        // The same signed message must not mint a second time.
        vm.expectRevert(bytes("WrappedBridge: message already processed"));
        wrappedBridge.mint(message, signatures);
    }

    function test_NativeBridgeRejectsReplay() public {
        // First create and mint the A -> B message.
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.recordLogs();
        nativeBridge.lock(CHAIN_B, alice, 10 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Message memory outbound = _messageFromLogs(logs);

        vm.chainId(CHAIN_B);
        wrappedBridge.mint(outbound, _sign(outbound, wrappedBridge));

        // Burn the received wHBR to create the B -> A message.
        uint256 wrappedAmount = outbound.amount / 1e12;
        vm.prank(alice);
        vm.recordLogs();
        wrappedBridge.burn(CHAIN_A, alice, wrappedAmount);

        logs = vm.getRecordedLogs();
        Message memory returnMessage = _messageFromLogs(logs);

        // Unlock once on Chain A.
        vm.chainId(CHAIN_A);
        bytes[] memory signatures = _sign(returnMessage, nativeBridge);
        nativeBridge.unlock(returnMessage, signatures);

        // Replaying the same message must fail.
        vm.expectRevert(bytes("NativeBridge: message already processed"));
        nativeBridge.unlock(returnMessage, signatures);
    }

    function test_WrappedBridgeRejectsDuplicateSigner() public {
        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.recordLogs();
        nativeBridge.lock(CHAIN_B, alice, 10 ether);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Message memory message = _messageFromLogs(logs);

        vm.chainId(CHAIN_B);
        bytes32 digest = wrappedBridge.messageDigest(message);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validatorKeys[0], digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes[] memory duplicateSignatures = new bytes[](2);
        duplicateSignatures[0] = signature;
        duplicateSignatures[1] = signature;

        vm.expectRevert(bytes("WrappedBridge: signers not sorted"));
        wrappedBridge.mint(message, duplicateSignatures);
    }

    function test_NonAdminCannotChangeValidators() public {
        address[] memory newValidators = new address[](1);
        newValidators[0] = alice;

        vm.chainId(CHAIN_A);
        vm.prank(alice);
        vm.expectRevert(bytes("NativeBridge: not admin"));
        nativeBridge.setValidators(newValidators, 1);
    }

    function _createValidators() internal {
        // Generate keys, then sort by address so signatures are ordered.
        for (uint256 i; i < 3; ++i) {
            validatorKeys[i] = uint256(keccak256(abi.encode("validator", i)));
            validators[i] = vm.addr(validatorKeys[i]);
        }

        for (uint256 i; i < 3; ++i) {
            for (uint256 j = i + 1; j < 3; ++j) {
                if (validators[j] < validators[i]) {
                    (validators[i], validators[j]) =
                        (validators[j], validators[i]);
                    (validatorKeys[i], validatorKeys[j]) =
                        (validatorKeys[j], validatorKeys[i]);
                }
            }
        }
    }

    function _validatorAddresses() internal view returns (address[] memory result) {
        result = new address[](3);
        for (uint256 i; i < 3; ++i) {
            result[i] = validators[i];
        }
    }

    function _sign(
        Message memory message,
        IHarborBridge destinationBridge
    ) internal returns (bytes[] memory signatures) {
        bytes32 digest = destinationBridge.messageDigest(message);
        signatures = new bytes[](THRESHOLD);

        for (uint256 i; i < THRESHOLD; ++i) {
            (uint8 v, bytes32 r, bytes32 s) =
                vm.sign(validatorKeys[i], digest);
            signatures[i] = abi.encodePacked(r, s, v);
        }
    }

   
function _messageFromLogs(
    Vm.Log[] memory logs
) internal pure returns (Message memory message) {
    bytes32 eventTopic = keccak256(
        "MessageSent(bytes32,(uint256,uint256,uint256,address,address,uint256,uint256,bytes))"
    );

    for (uint256 i; i < logs.length; ++i) {
        if (
            logs[i].topics.length > 0 &&
            logs[i].topics[0] == eventTopic
        ) {
            // messageId is indexed, so logs[i].data contains only Message.
            message = abi.decode(logs[i].data, (Message));
            return message;
        }
    }

    revert("MessageSent event not found");
}
}