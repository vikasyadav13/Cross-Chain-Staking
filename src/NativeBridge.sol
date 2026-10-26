
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {Message, INativeBridge} from "./interfaces/IHarborBridge.sol";

contract NativeBridge is INativeBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint256 public immutable remoteChainId;

    address public admin;
    uint256 public threshold;
    uint256 public nextNonce;

    address[] public validators;
    mapping(address => bool) public isValidator;
    mapping(bytes32 => bool) public processedMessages;

    event ValidatorsUpdated(address[] validators, uint256 threshold);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "NativeBridge: not admin");
        _;
    }

    constructor(
        address tokenAddress,
        uint256 remoteChainId_,
        address[] memory initialValidators,
        uint256 initialThreshold,
        address adminAddress
    ) {
        require(tokenAddress != address(0), "NativeBridge: zero token");
        require(adminAddress != address(0), "NativeBridge: zero admin");
        require(remoteChainId_ != 0, "NativeBridge: zero remote chain");
        require(
            remoteChainId_ != block.chainid,
            "NativeBridge: same chain"
        );

        token = IERC20(tokenAddress);
        remoteChainId = remoteChainId_;
        admin = adminAddress;

        _replaceValidators(initialValidators, initialThreshold);
    }

    function lock(
        uint256 dstChainId,
        address recipient,
        uint256 amount
    ) external override nonReentrant returns (bytes32 messageId) {
        _validateLock(dstChainId, recipient, amount);

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));

        require(
            balanceAfter > balanceBefore,
            "NativeBridge: no tokens received"
        );

        messageId = _emitMessage(
            recipient,
            balanceAfter - balanceBefore,
            0,
            bytes("")
        );
    }

    function lockWithHook(
        uint256 dstChainId,
        address recipient,
        uint256 amount,
        uint256 hookGasLimit,
        bytes calldata hookData
    ) external override nonReentrant returns (bytes32 messageId) {
        _validateLock(dstChainId, recipient, amount);

        require(hookGasLimit > 0, "NativeBridge: zero hook gas");
        require(hookData.length > 0, "NativeBridge: empty hook data");

        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));

        require(
            balanceAfter > balanceBefore,
            "NativeBridge: no tokens received"
        );

        messageId = _emitMessage(
            recipient,
            balanceAfter - balanceBefore,
            hookGasLimit,
            hookData
        );
    }

    function unlock(
        Message calldata message,
        bytes[] calldata signatures
    ) external override nonReentrant {
        require(
            message.srcChainId == remoteChainId,
            "NativeBridge: wrong source chain"
        );
        require(
            message.dstChainId == block.chainid,
            "NativeBridge: wrong destination chain"
        );
        require(message.sender != address(0), "NativeBridge: zero sender");
        require(
            message.recipient != address(0),
            "NativeBridge: zero recipient"
        );
        require(message.amount > 0, "NativeBridge: zero amount");
        require(
            message.hookGasLimit == 0 && message.hookData.length == 0,
            "NativeBridge: hooks not allowed"
        );

        bytes32 digest = _messageDigest(message);

        require(
            !processedMessages[digest],
            "NativeBridge: message already processed"
        );

        _verifySignatures(digest, signatures);

        // Mark before the external token transfer. A failed transfer reverts
        // this update along with the rest of the transaction.
        processedMessages[digest] = true;

        token.safeTransfer(message.recipient, message.amount);
    }

    function messageDigest(
        Message calldata message
    ) external view override returns (bytes32) {
        return _messageDigest(message);
    }

    function _messageDigest(
        Message calldata message
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                message.srcChainId,
                message.dstChainId,
                message.nonce,
                message.sender,
                message.recipient,
                message.amount,
                message.hookGasLimit,
                keccak256(message.hookData)
            )
        );
    }

    function setValidators(
        address[] calldata newValidators,
        uint256 newThreshold
    ) external override onlyAdmin {
        _replaceValidators(newValidators, newThreshold);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "NativeBridge: zero admin");

        address oldAdmin = admin;
        admin = newAdmin;

        emit AdminUpdated(oldAdmin, newAdmin);
    }

    function _validateLock(
        uint256 dstChainId,
        address recipient,
        uint256 amount
    ) internal view {
        require(
            dstChainId == remoteChainId,
            "NativeBridge: unsupported chain"
        );
        require(recipient != address(0), "NativeBridge: zero recipient");
        require(amount > 0, "NativeBridge: zero amount");
    }

    function _emitMessage(
        address recipient,
        uint256 amountReceived,
        uint256 hookGasLimit,
        bytes memory hookData
    ) internal returns (bytes32 messageId) {
        Message memory message = Message({
            srcChainId: block.chainid,
            dstChainId: remoteChainId,
            nonce: nextNonce++,
            sender: msg.sender,
            recipient: recipient,
            amount: amountReceived,
            hookGasLimit: hookGasLimit,
            hookData: hookData
        });

        messageId = keccak256(abi.encode(message));

        emit MessageSent(messageId, message);
    }

    function _verifySignatures(
        bytes32 digest,
        bytes[] calldata signatures
    ) internal view {
        require(
            signatures.length >= threshold,
            "NativeBridge: insufficient signatures"
        );
        require(
            signatures.length <= validators.length,
            "NativeBridge: too many signatures"
        );

        address previousSigner = address(0);

        for (uint256 i = 0; i < signatures.length; i++) {
            require(
                signatures[i].length == 65,
                "NativeBridge: invalid signature length"
            );

            address signer = ECDSA.recover(digest, signatures[i]);

            require(isValidator[signer], "NativeBridge: invalid validator");
            require(
                signer > previousSigner,
                "NativeBridge: signers not sorted"
            );

            previousSigner = signer;
        }
    }

    function _replaceValidators(
        address[] memory newValidators,
        uint256 newThreshold
    ) internal {
        require(
            newValidators.length > 0,
            "NativeBridge: empty validators"
        );
        require(
            newThreshold > 0 && newThreshold <= newValidators.length,
            "NativeBridge: invalid threshold"
        );

        for (uint256 i = 0; i < validators.length; i++) {
            isValidator[validators[i]] = false;
        }

        delete validators;

        for (uint256 i = 0; i < newValidators.length; i++) {
            address validator = newValidators[i];

            require(
                validator != address(0),
                "NativeBridge: zero validator"
            );
            require(
                !isValidator[validator],
                "NativeBridge: duplicate validator"
            );

            isValidator[validator] = true;
            validators.push(validator);
        }

        threshold = newThreshold;

        emit ValidatorsUpdated(newValidators, newThreshold);
    }
}
