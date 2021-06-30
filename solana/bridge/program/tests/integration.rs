#![allow(warnings)]

use borsh::BorshSerialize;
use secp256k1::Message;

use solana_client::rpc_client::RpcClient;
use solana_program::{
    borsh::try_from_slice_unchecked,
    hash,
    instruction::{
        AccountMeta,
        Instruction,
    },
    program_pack::Pack,
    pubkey::Pubkey,
    system_instruction::{
        self,
        create_account,
    },
    system_program,
    sysvar,
};
use solana_sdk::{
    signature::{
        read_keypair_file,
        Keypair,
        Signer,
    },
    transaction::Transaction,
};

use byteorder::{
    BigEndian,
    WriteBytesExt,
};

use std::{
    convert::TryInto,
    io::{
        Cursor,
        Write,
    },
};

use std::time::{
    Duration,
    SystemTime,
};

use sha3::Digest;
use hex_literal::hex;

use bridge::{
    accounts::GuardianSetDerivationData,
    instruction,
    types::{
        BridgeConfig,
        GovernancePayloadGuardianSetChange,
        PostedMessage,
        PostedMessageData,
        SequenceTracker,
        SignatureSet,
    },
    Initialize,
    PostVAAData,
    Signature,
    SerializePayload,
};

mod common;

/// Test messages coming from another chain other than Solana.
#[test]
fn test_alien_chain_messages() {
}

/// Ethereum Test Addresses (Keccak hashed Public Key)
const INITIAL_PUBLIC: [[u8; 20]; 2] = [
    hex!("1d72877eb2d898738afe94c6101152ede0435de9"),
    hex!("7C6824A51bD586ecdc866ECCc9cd04b317570dDB"),
];

/// Secp256k1 Secret Keys, used as the single initial guardian for testing.
const INITIAL_SECRET: [[u8; 32]; 2] = [
    hex!("99701c805ef938e13f0e48f09e2c327891c1d84729d152f301e7e62cbf1f91c9"),
    hex!("0e76b44615dcabbcd1e5060c9b18e879cd0d4a5a7323e15f48ef13169c179743"),
];

#[test]
fn test_bridge_messages() {
    // Data we want to verify exists, wrapped in a message the guardians can process.
    let nonce = 12397;
    let data = b"Prove Me".to_vec();

    // Initialize a wormhole bridge on Solana to test with.
    let (ref payer, ref client, ref program) = common::setup();

    // Keypair representing the emitting entity for our messages.
    let emitter = Keypair::new();

    // Initialize the Bridge.
    common::initialize(client, program, payer, &INITIAL_PUBLIC);

    // Post the message, publishing the data for guardian consumption.
    common::post_message(client, program, payer, &emitter, nonce, data.clone());

    // Emulate Guardian behaviour, verifying the data and publishing signatures/VAA.
    let (vaa, body, body_hash, keys) = guardian_sign_round(&emitter, data.clone(), nonce);
    common::verify_signatures(client, program, payer, body, body_hash, &keys);
    common::post_vaa(client, program, payer, vaa);

    // Upgrade the guardian set with a new set of guardians.
    let nonce = 12398;
    let data = update_guardian_set(1, &INITIAL_PUBLIC);
    let message_key = common::post_message(client, program, payer, &emitter, nonce, data.clone());

    common::upgrade_guardian_set(
        client,
        program,
        payer,
        message_key,
        emitter.pubkey(),
        0,
        1,
    );
}

fn update_guardian_set(
    index: u32,
    keys: &[[u8; 20]],
) -> Vec<u8> {
    let mut v = Cursor::new(Vec::new());
    v.write_u32::<BigEndian>(index).unwrap();
    v.write_u8(keys.len() as u8).unwrap();
    keys.iter().map(|key| v.write(key));
    v.into_inner()
}

/// A utility function for emulating what the guardians should be doing, I.E, detecting a message
/// is on the chain and creating a signature set for it.
fn guardian_sign_round(
    emitter: &Keypair,
    data: Vec<u8>,
    nonce: u32,
) -> (PostVAAData, Vec<u8>, [u8; 32], Vec<secp256k1::SecretKey>) {
    let mut vaa = PostVAAData {
        version: 0,
        guardian_set_index: 0,

        // Body part
        emitter_chain: 1,
        emitter_address: emitter.pubkey().to_bytes(),
        sequence: 0,
        payload: data,
        timestamp: SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs() as u32,
        nonce,
    };

    // Hash data, the thing we wish to actually sign.
    let body = {
        let mut v = Cursor::new(Vec::new());
        v.write_u32::<BigEndian>(vaa.timestamp).unwrap();
        v.write_u32::<BigEndian>(vaa.nonce).unwrap();
        v.write_u16::<BigEndian>(vaa.emitter_chain).unwrap();
        v.write(&vaa.emitter_address).unwrap();
        v.write_u64::<BigEndian>(vaa.sequence).unwrap();
        v.write(&vaa.payload).unwrap();
        v.into_inner()
    };

    // Hash this body, which is expected to be the same as the hash currently stored in the
    // signature account, binding that set of signatures to this VAA.
    let body_hash: [u8; 32] = {
        let mut h = sha3::Keccak256::default();
        h.write(body.as_slice()).unwrap();
        h.finalize().into()
    };

    // Sign with all available secret keys.
    let mut keys = Vec::new();
    for secret_key in INITIAL_SECRET.iter() {
        let secret_key = secp256k1::SecretKey::parse(secret_key).unwrap();
        keys.push(secret_key);
    }

    (vaa, body, body_hash, keys)
}