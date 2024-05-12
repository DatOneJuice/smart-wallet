// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {CoinbaseSmartWallet} from "../../src/CoinbaseSmartWallet.sol";
import {ERC1271} from "../../src/ERC1271.sol";
import {MultiOwnable} from "../../src/MultiOwnable.sol";
import {IKeyStore} from "../../src/ext/IKeyStore.sol";
import {IVerifier} from "../../src/ext/IVerifier.sol";

import {LibCoinbaseSmartWallet} from "../utils/LibCoinbaseSmartWallet.sol";
import {LibMultiOwnable} from "../utils/LibMultiOwnable.sol";

contract ERC1271Test is Test {
    address private keyStore = makeAddr("KeyStore");
    address private stateVerifier = makeAddr("StateVerifier");
    CoinbaseSmartWallet private sut;

    function setUp() public {
        sut = new CoinbaseSmartWallet({keyStore_: keyStore, stateVerifier_: stateVerifier});
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                             TESTS                                              //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    /// @custom:test-section isValidSignature

    function test_isValidSignature_returns0xffffffff_whenSignatureIsInvalid(
        uint248 privateKey,
        uint256 ksKey,
        uint256 ksKeyType,
        bytes32 h
    ) external {
        bytes memory signature = _setUpTestWrapper_isValidSignature({
            privateKey: privateKey,
            ksKey: ksKey,
            ksKeyType: ksKeyType,
            h: h,
            validSig: false,
            validStateProof: false
        });

        bytes4 result = sut.isValidSignature({hash: h, signature: signature});
        assertEq(result, bytes4(0xffffffff));
    }

    function test_isValidSignature_returns0xffffffff_whenStateProofIsInvalid(
        uint248 privateKey,
        uint256 ksKey,
        uint256 ksKeyType,
        bytes32 h
    ) external {
        bytes memory signature = _setUpTestWrapper_isValidSignature({
            privateKey: privateKey,
            ksKey: ksKey,
            ksKeyType: ksKeyType,
            h: h,
            validSig: true,
            validStateProof: false
        });

        bytes4 result = sut.isValidSignature({hash: h, signature: signature});
        assertEq(result, bytes4(0xffffffff));
    }

    function test_isValidSignature_returns0x1626ba7e_whenSignatureIsValidAndStateProofIsValid(
        uint248 privateKey,
        uint256 ksKey,
        uint256 ksKeyType,
        bytes32 h
    ) external {
        bytes memory signature = _setUpTestWrapper_isValidSignature({
            privateKey: privateKey,
            ksKey: ksKey,
            ksKeyType: ksKeyType,
            h: h,
            validSig: true,
            validStateProof: true
        });

        bytes4 result = sut.isValidSignature({hash: h, signature: signature});
        assertEq(result, bytes4(0x1626ba7e));
    }

    /// @custom:test-section eip712Domain

    function test_eip712Domain_returnsTheEip712DomainInformation() external {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = sut.eip712Domain();

        assertEq(fields, hex"0f");
        assertEq(keccak256(bytes(name)), keccak256("Coinbase Smart Wallet"));
        assertEq(keccak256(bytes(version)), keccak256("1"));
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(sut));
        assertEq(salt, bytes32(0));
        assertEq(abi.encode(extensions), abi.encode(new uint256[](0)));
    }

    /// @custom:test-section domainSeparator

    function test_domainSeparator_returnsTheDomainSeparator() external {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) = sut.eip712Domain();

        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
        assertEq(expected, sut.domainSeparator());
    }

    /// @custom:test-section replaySafeHash

    function test_replaySafeHash_returnsAnEip712HashOfTheGivenHash(uint256 privateKey, bytes32 h) external {
        // Setup test:
        // 1. Set the `.message.hash` key to `h` in "test/ERC1271/ERC712.json".
        // 2. Ensure `privateKey` is a valid private key.
        // 3. Create a wallet from the `privateKey`.
        Vm.Wallet memory wallet;
        {
            vm.writeJson({json: vm.toString(h), path: "test/ERC1271/ERC712.json", valueKey: ".message.hash"});

            privateKey = bound(privateKey, 1, type(uint248).max);
            wallet = vm.createWallet(privateKey, "Wallet");
        }

        bytes32 replaySafeHash = sut.replaySafeHash(h);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign({wallet: wallet, digest: replaySafeHash});

        string[] memory inputs = new string[](8);
        inputs[0] = "cast";
        inputs[1] = "wallet";
        inputs[2] = "sign";
        inputs[3] = "--data";
        inputs[4] = "--from-file";
        inputs[5] = "test/ERC1271/ERC712.json";
        inputs[6] = "--private-key";
        inputs[7] = vm.toString(bytes32(privateKey));

        bytes memory expectedSignature = vm.ffi(inputs);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertEq(signature, expectedSignature);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////
    //                                         TEST HELPERS                                           //
    ////////////////////////////////////////////////////////////////////////////////////////////////////

    function _setUpTestWrapper_isValidSignature(
        uint248 privateKey,
        uint256 ksKey,
        uint256 ksKeyType,
        bytes32 h,
        bool validSig,
        bool validStateProof
    ) private returns (bytes memory signature) {
        // Setup test:
        // 1. Pick the correct `sigWrapperDataBuilder` method depending on `ksKeyType`.
        // 2. Setup the test for `isValidSignature`;
        // 3. Expect calls if `validSig` is true.

        MultiOwnable.KeyspaceKeyType ksKeyType_ = LibMultiOwnable.uintToKsKeyType({value: ksKeyType, withNone: false});

        function (Vm.Wallet memory , bytes32, bool , bytes memory )  returns(bytes memory) sigWrapperDataBuilder;
        if (ksKeyType_ == MultiOwnable.KeyspaceKeyType.WebAuthn) {
            sigWrapperDataBuilder = LibCoinbaseSmartWallet.webAuthnSignatureWrapperData;
        } else if (ksKeyType_ == MultiOwnable.KeyspaceKeyType.Secp256k1) {
            sigWrapperDataBuilder = uint256(h) % 2 == 0
                ? LibCoinbaseSmartWallet.eoaSignatureWrapperData
                : LibCoinbaseSmartWallet.eip1271SignatureWrapperData;
        }

        Vm.Wallet memory wallet;
        (wallet, signature) = _setUpTest_isValidSignature({
            privateKey: privateKey,
            ksKey: ksKey,
            ksKeyType: ksKeyType_,
            h: h,
            validSig: validSig,
            validStateProof: validStateProof,
            sigWrapperDataBuilder: sigWrapperDataBuilder
        });

        if (validSig == true) {
            if (sigWrapperDataBuilder == LibCoinbaseSmartWallet.eip1271SignatureWrapperData) {
                vm.expectCall({callee: wallet.addr, data: abi.encodeWithSelector(ERC1271.isValidSignature.selector)});
            }

            vm.expectCall({callee: keyStore, data: abi.encodeWithSelector(IKeyStore.root.selector)});
            vm.expectCall({callee: stateVerifier, data: abi.encodeWithSelector(IVerifier.Verify.selector)});
        }
    }

    function _setUpTest_isValidSignature(
        uint248 privateKey,
        uint256 ksKey,
        MultiOwnable.KeyspaceKeyType ksKeyType,
        bytes32 h,
        bool validSig,
        bool validStateProof,
        function (Vm.Wallet memory , bytes32, bool , bytes memory )  returns(bytes memory) sigWrapperDataBuilder
    ) private returns (Vm.Wallet memory wallet, bytes memory signature) {
        // Setup test:
        // 1. Create an Secp256k1/Secp256r1 wallet.
        // 2. Add the owner as `ksKeyType`.
        // 3. Create a valid or invalid `signature` of `replaySafeHash(h)` depending on `validSig`.
        //    NOTE: Invalid signatures are still correctly encoded.
        // 4. Mock `IKeyStore.root` to revert or return 42 depending on `validSig`.
        //    NOTE: Reverting ensure `isValidSignature` returns before calling `IKeyStore.root`.
        // 5. If `validSig` is true, mock `IVerifier.Verify` to return `validStateProof`.

        wallet = ksKeyType == MultiOwnable.KeyspaceKeyType.WebAuthn
            ? LibCoinbaseSmartWallet.passKeyWallet(privateKey)
            : LibCoinbaseSmartWallet.wallet(privateKey);

        LibMultiOwnable.cheat_AddOwner({target: address(sut), ksKey: ksKey, ksKeyType: ksKeyType});

        CoinbaseSmartWallet.SignatureWrapper memory sigWrapper = CoinbaseSmartWallet.SignatureWrapper({
            ksKey: ksKey,
            data: sigWrapperDataBuilder(wallet, sut.replaySafeHash(h), validSig, "STATE PROOF")
        });

        signature = LibCoinbaseSmartWallet.userOpSignature(sigWrapper);

        if (validSig == false) {
            LibCoinbaseSmartWallet.mockRevertKeyStore({keyStore: keyStore, revertData: "SHOULD RETURN FALSE BEFORE"});
        } else {
            LibCoinbaseSmartWallet.mockKeyStore({keyStore: keyStore, root: 42});
            LibCoinbaseSmartWallet.mockStateVerifier({stateVerifier: stateVerifier, value: validStateProof});
        }
    }
}