// contracts/Bridge.sol
// SPDX-License-Identifier: Apache 2

pragma solidity ^0.8.0;

import "../libraries/external/BytesLib.sol";
import "@pythnetwork/pyth-sdk-solidity/AbstractPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

import "./PythGetters.sol";
import "./PythSetters.sol";
import "./PythInternalStructs.sol";

abstract contract Pyth is PythGetters, PythSetters, AbstractPyth {
    using BytesLib for bytes;

    function _initialize(
        address wormhole,
        uint16 pyth2WormholeChainId,
        bytes32 pyth2WormholeEmitter
    ) internal {
        setWormhole(wormhole);
        setPyth2WormholeChainId(pyth2WormholeChainId);
        setPyth2WormholeEmitter(pyth2WormholeEmitter);
    }

    function updatePriceBatchFromVm(bytes calldata encodedVm) private {
        (IWormhole.VM memory vm, bool valid, string memory reason) = wormhole().parseAndVerifyVM(encodedVm);

        require(valid, reason);
        require(verifyPythVM(vm), "invalid data source chain/emitter ID");

        parseAndProcessBatchPriceAttestation(vm);
    }

    function updatePriceFeeds(bytes[] calldata updateData) public override payable {
        uint requiredFee = getUpdateFee(updateData);
        require(msg.value >= requiredFee, "insufficient paid fee amount");
 
        for(uint i = 0; i < updateData.length; ) {
            updatePriceBatchFromVm(updateData[i]);

            unchecked { i++; }
        }

        emit UpdatePriceFeeds(msg.sender, updateData.length, requiredFee);
    }

    /// This method is deprecated, please use the `getUpdateFee(bytes[])` instead.
    function getUpdateFee(uint updateDataSize) public view returns (uint feeAmount) {
        return singleUpdateFeeInWei() * updateDataSize;
    }

    function getUpdateFee(bytes[] calldata updateData) public override view returns (uint feeAmount) {
        return singleUpdateFeeInWei() * updateData.length;
    }

    function verifyPythVM(IWormhole.VM memory vm) private view returns (bool valid) {
        return isValidDataSource(vm.emitterChainId, vm.emitterAddress); 
    }

    function parseAndProcessBatchPriceAttestation(IWormhole.VM memory vm) internal {
        // Most of the math operations below are simple additions.
        // In the places that there is more complex operation there is
        // a comment explaining why it is safe. Also, byteslib
        // operations have proper require.
        unchecked {
            bytes memory encoded = vm.payload;    
            uint index = 0;

            // Check header
            {
                uint32 magic = encoded.toUint32(index);
                index += 4;
                require(magic == 0x50325748, "invalid magic value");

                uint16 versionMajor = encoded.toUint16(index);
                index += 2;
                require(versionMajor == 3, "invalid version major, expected 3");

                uint16 versionMinor = encoded.toUint16(index);
                index += 2;
                require(versionMinor >= 0, "invalid version minor, expected 0 or more");

                uint16 hdrSize = encoded.toUint16(index);
                index += 2;

                // NOTE(2022-04-19): Currently, only payloadId comes after
                // hdrSize. Future extra header fields must be read using a
                // separate offset to respect hdrSize, i.e.:
                //
                // uint hdrIndex = 0;
                // bpa.header.payloadId = encoded.toUint8(index + hdrIndex);
                // hdrIndex += 1;
                //
                // bpa.header.someNewField = encoded.toUint32(index + hdrIndex);
                // hdrIndex += 4;
                //
                // // Skip remaining unknown header bytes
                // index += bpa.header.hdrSize;

                uint8 payloadId = encoded.toUint8(index);

                // Skip remaining unknown header bytes
                index += hdrSize;

                // Payload ID of 2 required for batch headerBa
                require(payloadId == 2, "invalid payload ID, expected 2 for BatchPriceAttestation");
            }

            // Parse the number of attestations
            uint16 nAttestations = encoded.toUint16(index);
            index += 2;

            // Parse the attestation size
            uint16 attestationSize = encoded.toUint16(index);
            index += 2;

            // Given the message is valid the arithmetic below should not overflow, and
            // even if it overflows then the require would fail.
            require(encoded.length == (index + (attestationSize * nAttestations)), "invalid BatchPriceAttestation size");

            PythInternalStructs.PriceInfo memory info;
            bytes32 priceId;
            uint freshPrices = 0;
            
            // Deserialize each attestation
            for (uint j=0; j < nAttestations; j++) {
                // NOTE: We don't advance the global index immediately.
                // attestationIndex is an attestation-local offset used
                // for readability and easier debugging.
                uint attestationIndex = 0;

                // Unused bytes32 product id
                attestationIndex += 32;

                priceId = encoded.toBytes32(index + attestationIndex);
                attestationIndex += 32;

                info.price = int64(encoded.toUint64(index + attestationIndex));
                attestationIndex += 8;

                info.conf = encoded.toUint64(index + attestationIndex);
                attestationIndex += 8;

                info.expo = int32(encoded.toUint32(index + attestationIndex));
                attestationIndex += 4;

                info.emaPrice = int64(encoded.toUint64(index + attestationIndex));
                attestationIndex += 8;

                info.emaConf = encoded.toUint64(index + attestationIndex);
                attestationIndex += 8;

                {
                    // Status is an enum (encoded as uint8) with the following values:
                    // 0 = UNKNOWN: The price feed is not currently updating for an unknown reason.
                    // 1 = TRADING: The price feed is updating as expected.
                    // 2 = HALTED: The price feed is not currently updating because trading in the product has been halted.
                    // 3 = AUCTION: The price feed is not currently updating because an auction is setting the price.
                    uint8 status = encoded.toUint8(index + attestationIndex);
                    attestationIndex += 1;

                    // Unused uint32 numPublishers
                    attestationIndex += 4;

                    // Unused uint32 numPublishers
                    attestationIndex += 4;

                    // Unused uint64 attestationTime
                    attestationIndex += 8;

                    info.publishTime = encoded.toUint64(index + attestationIndex);
                    attestationIndex += 8;

                    if (status == 1) { // status == TRADING
                        attestationIndex += 24;
                    } else {
                        // If status is not trading then the latest available price is
                        // the previous price info that are passed here.

                        // Previous publish time
                        info.publishTime = encoded.toUint64(index + attestationIndex);
                        attestationIndex += 8;

                        // Previous price
                        info.price = int64(encoded.toUint64(index + attestationIndex));
                        attestationIndex += 8;

                        // Previous confidence
                        info.conf = encoded.toUint64(index + attestationIndex);
                        attestationIndex += 8;
                    }
                }


                require(attestationIndex <= attestationSize, "INTERNAL: Consumed more than `attestationSize` bytes");

                // Respect specified attestation size for forward-compat
                index += attestationSize;

                // Store the attestation
                uint64 latestPublishTime = latestPriceInfoPublishTime(priceId);

                bool fresh = false;
                if(info.publishTime > latestPublishTime) {
                    freshPrices += 1;
                    fresh = true;
                    setLatestPriceInfo(priceId, info);
                }

                emit PriceFeedUpdate(priceId, fresh, vm.emitterChainId, vm.sequence, latestPublishTime,
                    info.publishTime, info.price, info.conf);
            }


            emit BatchPriceFeedUpdate(vm.emitterChainId, vm.sequence, nAttestations, freshPrices);
        }
    }

    function queryPriceFeed(bytes32 id) public view override returns (PythStructs.PriceFeed memory priceFeed){
        // Look up the latest price info for the given ID
        PythInternalStructs.PriceInfo memory info = latestPriceInfo(id);
        require(info.publishTime != 0, "price feed for the given id is not pushed or does not exist");

        priceFeed.id = id;
        priceFeed.price.price = info.price;
        priceFeed.price.conf = info.conf;
        priceFeed.price.expo = info.expo;
        priceFeed.price.publishTime = uint(info.publishTime);

        priceFeed.emaPrice.price = info.emaPrice;
        priceFeed.emaPrice.conf = info.emaConf;
        priceFeed.emaPrice.expo = info.expo;
        priceFeed.emaPrice.publishTime = uint(info.publishTime);
    }

    function priceFeedExists(bytes32 id) public override view returns (bool) {
        return (latestPriceInfoPublishTime(id) != 0);
    }

    function getValidTimePeriod() public override view returns (uint) {
        return validTimePeriodSeconds();
    }

    function version() public pure returns (string memory) {
        return "1.1.0";
    }
}
