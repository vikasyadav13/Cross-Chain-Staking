
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {NativeBridgeV0} from "../src/NativeBridgeV0.sol";
import {HarborToken} from "../src/token/HarborToken.sol";
import {Message} from "../src/interfaces/IHarborBridge.sol";

contract NativeBridgeV0Test is Test {
    uint256 internal constant KEY1 = 0xA11CE;
    uint256 internal constant KEY2 = 0xB0B;
    uint256 internal constant KEY3 = 0xC0FFEE;

    address internal validator1;
    address internal validator2;
    address internal validator3;

    HarborToken internal token;
    NativeBridgeV0 internal bridge;

    function setUp() public {
        validator1 = vm.addr(KEY1);
        validator2 = vm.addr(KEY2);
        validator3 = vm.addr(KEY3);

        token = new HarborToken(address(this), address(0xFEE));

        bridge = new NativeBridgeV0(
            address(token),
            _validators3(),
            2,
            address(this)
        );

        token.approve(address(bridge), type(uint256).max);
        token.transfer(address(bridge), 1_000 ether);
    }

    // ============================================================
    // ORIGINAL 10 TESTS
    // ============================================================

    function testAnyoneCanChangeValidators() public {
        address attacker = address(0xBAD);
        address[] memory newValidators = new address[](1);
        newValidators[0] = attacker;

        vm.prank(attacker);
        bridge.setValidators(newValidators, 1);

        assertTrue(bridge.isValidator(attacker));
        assertEq(bridge.threshold(), 1);
    }

    function testConstructorAcceptsImpossibleThreshold() public {
        address[] memory noValidators = new address[](0);

        NativeBridgeV0 target = new NativeBridgeV0(
            address(token),
            noValidators,
            5,
            address(this)
        );

        assertEq(target.threshold(), 5);
    }

    function testConstructorAcceptsZeroTokenAndAdmin() public {
        NativeBridgeV0 target = new NativeBridgeV0(
            address(0),
            _validators1(),
            1,
            address(0)
        );

        assertEq(address(target.token()), address(0));
        assertEq(target.admin(), address(0));
    }

    function testDuplicateSignatureCountsTowardThresholdTwice() public {
        Message memory message = _message(4, address(this), 1 ether);
        bytes memory signature = _sign(KEY1, message);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = signature;
        signatures[1] = signature;

        uint256 beforeBalance = token.balanceOf(address(this));
        bridge.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testLockDoesNotEmitRequiredBridgeMessage() public {
        vm.recordLogs();
        bridge.lock(2, address(this), 1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 lockedTopic = keccak256("Locked(address,uint256)");
        bytes32 messageSentTopic = keccak256(
            "MessageSent(bytes32,(uint256,uint256,uint256,address,address,uint256,uint256,bytes))"
        );

        bool sawLocked;
        bool sawMessageSent;

        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0) {
                if (logs[i].topics[0] == lockedTopic) {
                    sawLocked = true;
                }
                if (logs[i].topics[0] == messageSentTopic) {
                    sawMessageSent = true;
                }
            }
        }

        assertTrue(sawLocked);
        assertFalse(sawMessageSent);
    }

    function testRemovedValidatorRemainsAuthorized() public {
        address[] memory replacement = new address[](1);
        replacement[0] = validator2;

        bridge.setValidators(replacement, 1);

        assertTrue(bridge.isValidator(validator1));
        assertTrue(bridge.isValidator(validator2));
    }

    function testSameMessageCanBeUnlockedTwice() public {
        Message memory message = _message(7, address(this), 1 ether);

        bytes[] memory firstSignatures = new bytes[](2);
        firstSignatures[0] = _sign(KEY1, message);
        firstSignatures[1] = _sign(KEY2, message);

        bytes[] memory secondSignatures = new bytes[](2);
        secondSignatures[0] = _sign(KEY2, message);
        secondSignatures[1] = _sign(KEY3, message);

        uint256 beforeBalance = token.balanceOf(address(this));

        bridge.unlock(message, firstSignatures);
        bridge.unlock(message, secondSignatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testTransferFeeUndercollateralizesBridgeDeposit() public {
        uint256 amount = 100 ether;
        uint256 beforeBridgeBalance = token.balanceOf(address(bridge));

        bridge.lock(2, address(this), amount);

        uint256 received =
            token.balanceOf(address(bridge)) - beforeBridgeBalance;

        assertLt(received, amount);
        assertEq(received, amount - (amount * 30 / 10_000));
    }

    function testUnsignedMessageFieldsCanBeChanged() public {
        Message memory signedMessage =
            _message(9, address(this), 1 ether);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(KEY1, signedMessage);
        signatures[1] = _sign(KEY2, signedMessage);

        Message memory changedMessage = signedMessage;
        changedMessage.amount = 2 ether;
        changedMessage.sender = address(0xDEAD);
        changedMessage.srcChainId = 999;
        changedMessage.dstChainId = 888;

        uint256 beforeBalance = token.balanceOf(address(this));
        bridge.unlock(changedMessage, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testZeroThresholdAllowsUnauthorizedUnlock() public {
        address[] memory noValidators = new address[](0);

        NativeBridgeV0 target = new NativeBridgeV0(
            address(token),
            noValidators,
            0,
            address(this)
        );

        token.transfer(address(target), 10 ether);

        Message memory message = _message(10, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = new bytes(65);

        uint256 beforeBalance = token.balanceOf(address(this));
        target.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    // ============================================================
    // 13 ADDITIONAL TESTS
    // ============================================================

    function testReplayAcrossDifferentSignerSubsets() public {
        Message memory message = _message(11, address(this), 1 ether);

        bytes[] memory quorumA = new bytes[](2);
        quorumA[0] = _sign(KEY1, message);
        quorumA[1] = _sign(KEY2, message);

        bytes[] memory quorumB = new bytes[](2);
        quorumB[0] = _sign(KEY2, message);
        quorumB[1] = _sign(KEY3, message);

        uint256 beforeBalance = token.balanceOf(address(this));

        bridge.unlock(message, quorumA);
        bridge.unlock(message, quorumB);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testZeroAddressValidatorAcceptsGarbageSignature() public {
        address[] memory zeroValidator = new address[](1);
        zeroValidator[0] = address(0);

        NativeBridgeV0 target = new NativeBridgeV0(
            address(token),
            zeroValidator,
            1,
            address(this)
        );

        token.transfer(address(target), 10 ether);

        Message memory message = _message(12, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = new bytes(65);

        uint256 beforeBalance = token.balanceOf(address(this));
        target.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testReplayAcrossBridgeDeployments() public {
        NativeBridgeV0 first = new NativeBridgeV0(
            address(token), _validators1(), 1, address(this)
        );
        NativeBridgeV0 second = new NativeBridgeV0(
            address(token), _validators1(), 1, address(this)
        );

        token.transfer(address(first), 10 ether);
        token.transfer(address(second), 10 ether);

        Message memory message = _message(13, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(KEY1, message);

        first.unlock(message, signatures);
        second.unlock(message, signatures);

        assertTrue(first.usedSignature(keccak256(signatures[0])));
        assertTrue(second.usedSignature(keccak256(signatures[0])));
    }

    function testVZeroOrOneSignatureIsRejected() public {
        Message memory message = _message(14, address(this), 1 ether);
        bytes32 digest = _digest(message);

        (, bytes32 r, bytes32 s) = vm.sign(KEY1, digest);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, uint8(0));

        vm.expectRevert(bytes("not enough signatures"));
        bridge.unlock(message, signatures);
    }

    function testFalseReturnTokenIsIgnored() public {
        FalseReturnToken falseToken = new FalseReturnToken();

        NativeBridgeV0 target = new NativeBridgeV0(
            address(falseToken),
            _validators1(),
            1,
            address(this)
        );

        target.lock(2, address(this), 1 ether);
        assertEq(falseToken.balanceOf(address(target)), 0);

        Message memory message = _message(15, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(KEY1, message);

        target.unlock(message, signatures);

        assertTrue(target.usedSignature(keccak256(signatures[0])));
        assertEq(falseToken.balanceOf(address(this)), 0);
    }

    function testLockAcceptsInvalidInputs() public {
        uint256 beforeBalance = token.balanceOf(address(bridge));

        bridge.lock(0, address(0), 0);

        assertEq(token.balanceOf(address(bridge)), beforeBalance);
    }

    function testReentrantUnlockCanPayTwice() public {
        CallbackToken callbackToken = new CallbackToken();

        NativeBridgeV0 target = new NativeBridgeV0(
            address(callbackToken),
            _validators1(),
            1,
            address(this)
        );

        callbackToken.mint(address(target), 10 ether);

        Message memory message = _message(17, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(KEY1, message);

        callbackToken.setCallback(
            address(target),
            abi.encodeWithSelector(
                NativeBridgeV0.unlock.selector,
                message,
                signatures
            )
        );

        target.unlock(message, signatures);

        assertEq(callbackToken.balanceOf(address(this)), 2 ether);
    }

    function testBareDigestSignatureIsAccepted() public {
        Message memory message = _message(18, address(this), 1 ether);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(KEY1, message);
        signatures[1] = _sign(KEY2, message);

        uint256 beforeBalance = token.balanceOf(address(this));
        bridge.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testEmptySignatureArrayReverts() public {
        Message memory message = _message(19, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](0);

        vm.expectRevert();
        bridge.unlock(message, signatures);
    }

    function testDuplicateValidatorsAreAccepted() public {
        address[] memory duplicateValidators = new address[](2);
        duplicateValidators[0] = validator1;
        duplicateValidators[1] = validator1;

        NativeBridgeV0 target = new NativeBridgeV0(
            address(token),
            duplicateValidators,
            2,
            address(this)
        );

        token.transfer(address(target), 10 ether);

        Message memory message = _message(20, address(this), 1 ether);
        bytes memory signature = _sign(KEY1, message);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = signature;
        signatures[1] = signature;

        uint256 beforeBalance = token.balanceOf(address(this));
        target.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testUnauthorizedValidatorReplacementEnablesWithdrawal() public {
        address attacker = vm.addr(KEY3);

        address[] memory newValidators = new address[](1);
        newValidators[0] = attacker;

        vm.prank(attacker);
        bridge.setValidators(newValidators, 1);

        Message memory message = _message(21, address(this), 1 ether);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _sign(KEY3, message);

        uint256 beforeBalance = token.balanceOf(address(this));
        bridge.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testLargeWithdrawalHasNoConfiguredCap() public {
        Message memory message = _message(22, address(this), 500 ether);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(KEY1, message);
        signatures[1] = _sign(KEY2, message);

        uint256 beforeBalance = token.balanceOf(address(this));
        bridge.unlock(message, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function testHookDataAndOtherFieldsCanBeAltered() public {
        Message memory original = _message(23, address(this), 1 ether);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(KEY1, original);
        signatures[1] = _sign(KEY2, original);

        Message memory changed = original;
        changed.sender = address(0xDEAD);
        changed.srcChainId = 999;
        changed.dstChainId = 888;
        changed.amount = 2 ether;
        changed.hookGasLimit = 500_000;
        changed.hookData = hex"deadbeef";

        uint256 beforeBalance = token.balanceOf(address(this));
        bridge.unlock(changed, signatures);

        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    // ============================================================
    // HELPERS
    // ============================================================

    function _message(
        uint256 nonce,
        address recipient,
        uint256 amount
    ) internal pure returns (Message memory) {
        return Message({
            srcChainId: 1,
            dstChainId: 2,
            nonce: nonce,
            sender: address(0x1234),
            recipient: recipient,
            amount: amount,
            hookGasLimit: 0,
            hookData: ""
        });
    }

    function _digest(
        Message memory message
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(message.nonce, message.recipient));
    }

    function _sign(
        uint256 privateKey,
        Message memory message
    ) internal pure returns (bytes memory) {
        bytes32 digest = _digest(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _validators1()
        internal
        view
        returns (address[] memory result)
    {
        result = new address[](1);
        result[0] = validator1;
    }

    function _validators3()
        internal
        view
        returns (address[] memory result)
    {
        result = new address[](3);
        result[0] = validator1;
        result[1] = validator2;
        result[2] = validator3;
    }
}

contract FalseReturnToken {
    mapping(address => uint256) public balanceOf;

    function transferFrom(address, address, uint256)
        external
        pure
        returns (bool)
    {
        return false;
    }

    function transfer(address, uint256)
        external
        pure
        returns (bool)
    {
        return false;
    }
}

contract CallbackToken {
    mapping(address => uint256) public balanceOf;

    address internal callbackTarget;
    bytes internal callbackData;
    bool internal callbackArmed;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
        callbackArmed = true;
    }

    function transferFrom(address, address, uint256)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function transfer(address to, uint256 amount)
        external
        returns (bool)
    {
        if (callbackArmed) {
            callbackArmed = false;
            (bool success, ) = callbackTarget.call(callbackData);
            require(success, "callback failed");
        }

        require(balanceOf[msg.sender] >= amount, "insufficient balance");

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
