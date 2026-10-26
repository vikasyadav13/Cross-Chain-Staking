
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {
    Message,
    IBridgeHookReceiver,
    IWrappedBridge
} from "./interfaces/IHarborBridge.sol";
import {WrappedHarbor} from "./token/WrappedHarbor.sol";

contract WrappedBridge is IWrappedBridge, ReentrancyGuard {
    uint256 private constant CONVERSION_FACTOR = 1e12;

    WrappedHarbor public immutable token;
    uint256 public immutable remoteChainId;

    address public admin;
    uint256 public threshold;
    uint256 public nextNonce;

    mapping(address => bool) public isValidator;
    mapping(bytes32 => bool) public processedMessages;

    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event ValidatorsUpdated(address[] validators, uint256 threshold);
    event HookCallResult(bytes32 indexed messageId, bool success);

    modifier onlyAdmin() {
        require(msg.sender == admin, "WrappedBridge: not admin");
        _;
    }

    constructor(
        address tokenAddress,
        uint256 remoteChainId_,
        address[] memory initialValidators,
        uint256 initialThreshold,
        address adminAddress
    ) {
        require(tokenAddress != address(0), "WrappedBridge: zero token");
        require(adminAddress != address(0), "WrappedBridge: zero admin");
        require(remoteChainId_ != 0, "WrappedBridge: zero remote chain");
        require(
            remoteChainId_ != block.chainid,
            "WrappedBridge: same chain"
        );

        token = WrappedHarbor(tokenAddress);
        remoteChainId = remoteChainId_;
        admin = adminAddress;

        _setValidators(initialValidators, initialThreshold);
    }

    /// @notice Burn wHBR on this chain and create an HBR-denominated message.
    /// @param amount Amount of wHBR in its native 6-decimal units.
    function burn(
        uint256 dstChainId,
        address recipient,
        uint256 amount
    ) external override nonReentrant returns (bytes32 messageId) {
        require(
            dstChainId == remoteChainId,
            "WrappedBridge: wrong destination"
        );
        require(recipient != address(0), "WrappedBridge: zero recipient");
        require(amount > 0, "WrappedBridge: zero amount");

        // The caller supplies wHBR units (6 decimals).
        // The message always stores HBR units (18 decimals).
        uint256 hbrAmount = amount * CONVERSION_FACTOR;
        require(
            hbrAmount / CONVERSION_FACTOR == amount,
            "WrappedBridge: amount overflow"
        );

        token.bridgeBurn(msg.sender, amount);

        Message memory message = Message({
            srcChainId: block.chainid,
            dstChainId: dstChainId,
            nonce: nextNonce++,
            sender: msg.sender,
            recipient: recipient,
            amount: hbrAmount,
            hookGasLimit: 0,
            hookData: bytes("")
        });

        messageId = _messageDigest(message);
        emit MessageSent(messageId, message);
    }

    /// @notice Mint wHBR after validating a message and validator signatures.
    function mint(
        Message calldata message,
        bytes[] calldata signatures
    ) external override nonReentrant {
        require(
            message.srcChainId == remoteChainId,
            "WrappedBridge: wrong source"
        );
        require(
            message.dstChainId == block.chainid,
            "WrappedBridge: wrong destination chain"
        );
        require(message.sender != address(0), "WrappedBridge: zero sender");
        require(
            message.recipient != address(0),
            "WrappedBridge: zero recipient"
        );
        require(message.amount > 0, "WrappedBridge: zero amount");
        require(
            message.amount % CONVERSION_FACTOR == 0,
            "WrappedBridge: invalid precision"
        );

        bool hasHook = message.hookData.length != 0;

        if (hasHook) {
            require(
                message.hookGasLimit > 0,
                "WrappedBridge: zero hook gas"
            );
            require(
                message.recipient.code.length > 0,
                "WrappedBridge: recipient has no code"
            );
        } else {
            require(
                message.hookGasLimit == 0,
                "WrappedBridge: gas without hook"
            );
        }

        bytes32 messageId = _messageDigest(message);
        require(
            !processedMessages[messageId],
            "WrappedBridge: message already processed"
        );

        _verifySignatures(messageId, signatures);

        // Mark processed before any external token or hook calls.
        processedMessages[messageId] = true;

        uint256 wrappedAmount = message.amount / CONVERSION_FACTOR;

        // Initially mint to the recipient, which is the hook contract
        // for bridge-and-stake messages.
        token.bridgeMint(message.recipient, wrappedAmount);

        if (hasHook) {
            // A hook failure must not undo the bridge mint.
            // The failed subcall's state changes are reverted automatically.
            (bool success, ) = message.recipient.call{
                gas: message.hookGasLimit
            }(
                abi.encodeCall(
                    IBridgeHookReceiver.onBridgeReceived,
                    (
                        message.srcChainId,
                        message.sender,
                        wrappedAmount,
                        message.hookData
                    )
                )
            );

            emit HookCallResult(messageId, success);

            if (!success) {
                // The hook failed, so return the minted tokens to the
                // original sender instead of leaving them stuck at the hook.
                token.bridgeBurn(message.recipient, wrappedAmount);
                token.bridgeMint(message.sender, wrappedAmount);
            }
        }
    }

    /// @notice Return the digest validators must sign for this destination.
    function messageDigest(
        Message calldata message
    ) external view override returns (bytes32) {
        return _messageDigest(message);
    }

    function setValidators(
        address[] calldata newValidators,
        uint256 newThreshold
    ) external override onlyAdmin {
        _setValidators(newValidators, newThreshold);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "WrappedBridge: zero admin");

        address oldAdmin = admin;
        admin = newAdmin;

        emit AdminChanged(oldAdmin, newAdmin);
    }

    function _messageDigest(
        Message memory message
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

    function _verifySignatures(
        bytes32 digest,
        bytes[] calldata signatures
    ) internal view {
        require(
            signatures.length >= threshold,
            "WrappedBridge: insufficient signatures"
        );

        address previousSigner = address(0);

        for (uint256 i; i < signatures.length; ++i) {
            require(
                signatures[i].length == 65,
                "WrappedBridge: invalid signature length"
            );

            address signer = ECDSA.recover(digest, signatures[i]);

            require(
                isValidator[signer],
                "WrappedBridge: invalid validator"
            );
            require(
                signer > previousSigner,
                "WrappedBridge: signers not sorted"
            );

            previousSigner = signer;
        }
    }

    function _setValidators(
        address[] memory newValidators,
        uint256 newThreshold
    ) internal {
        require(
            newThreshold > 0 && newThreshold <= newValidators.length,
            "WrappedBridge: invalid threshold"
        );

        // Clear the old validator set.
        // This function is only called during construction or by the admin.
        // Existing validators are tracked separately so removed validators
        // cannot remain authorized.
        // For replacement, clear the previous entries before adding new ones.
        // We use the previous set stored in _validatorList.
        for (uint256 i; i < _validatorList.length; ++i) {
            isValidator[_validatorList[i]] = false;
        }
        delete _validatorList;

        for (uint256 i; i < newValidators.length; ++i) {
            address validator = newValidators[i];

            require(
                validator != address(0),
                "WrappedBridge: zero validator"
            );
            require(
                !isValidator[validator],
                "WrappedBridge: duplicate validator"
            );

            isValidator[validator] = true;
            _validatorList.push(validator);
        }

        threshold = newThreshold;

        emit ValidatorsUpdated(newValidators, newThreshold);
    }

    address[] private _validatorList;
}

