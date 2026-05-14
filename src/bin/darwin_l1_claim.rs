//! Darwin-flavoured L1-side claim CLI — fetches the merkle proof for
//! a pending Miden→L1 bridge-out from `zkevm-bridge-service`, then
//! calls `claimAsset` on the PolygonZkEVMBridgeV2 deployment to mint
//! the wDCC into the destination address.
//!
//! Symmetric to `darwin_bridge_out`: where that binary submits the
//! B2AGG note on Miden, this one consumes the resulting bridge-service
//! deposit record on L1 and finalises the round-trip.
//!
//! Pure Rust / alloy stack — no docker required to RUN the binary,
//! though it needs an L1 RPC that hosts the bridge contracts (anvil
//! brought up by `darwin-bridge-up.sh` is the canonical target).
//!
//! Usage:
//!   cargo run -p darwin-bridge-adapter --features=client \
//!       --bin darwin_l1_claim -- \
//!       --l1-rpc-url http://localhost:8545 \
//!       --bridge-service-url http://localhost:18080 \
//!       --bridge-address 0xC8cbEBf950B9Df44d987c8619f092beA980fF038 \
//!       --dest-address 0x71562b71999873DB5b286dF957af199Ec94617F7 \
//!       --funded-key 0x12d7…c625

use std::time::Duration;

use anyhow::{anyhow, Context};
use clap::Parser;
use darwin_bridge_adapter::EthAddress as DarwinEthAddress;

const POLL_INTERVAL: Duration = Duration::from_secs(5);
const POLL_MAX_ATTEMPTS: u32 = 24; // ~2 minutes

#[derive(Parser, Debug)]
#[command(version, about = "Darwin-flavoured L1 claimAsset CLI for AggLayer bridge-out")]
struct Args {
    /// L1 RPC URL (Anvil for local dev, Sepolia / Ethereum for prod)
    #[arg(long)]
    l1_rpc_url: String,

    /// zkevm-bridge-service REST URL (typically http://localhost:18080
    /// when running upstream's docker stack)
    #[arg(long)]
    bridge_service_url: String,

    /// PolygonZkEVMBridgeV2 address on L1
    #[arg(long)]
    bridge_address: String,

    /// L1 destination address (must match the dest-address used in
    /// the prior darwin_bridge_out call)
    #[arg(long)]
    dest_address: String,

    /// Private key (hex) that signs the claimAsset tx. Must hold
    /// enough L1 ETH for gas.
    #[arg(long, env = "DARWIN_L1_FUNDED_KEY")]
    funded_key: String,

    /// Optional deposit_cnt to claim explicitly. Without this we pick
    /// the first ready_for_claim deposit for the destination.
    #[arg(long)]
    deposit_cnt: Option<u64>,

    /// Wait up to this many seconds for the deposit to become
    /// ready_for_claim. Default: 120s.
    #[arg(long, default_value_t = 120)]
    wait_timeout_s: u64,
}

#[derive(serde::Deserialize, Debug)]
struct BridgeDeposit {
    deposit_cnt: u64,
    network_id: u32,
    orig_net: u32,
    orig_addr: String,
    dest_net: u32,
    dest_addr: String,
    amount: String,
    #[serde(default)]
    metadata: Option<String>,
    global_index: String,
    ready_for_claim: bool,
}

#[derive(serde::Deserialize)]
struct BridgesResponse {
    deposits: Vec<BridgeDeposit>,
}

#[derive(serde::Deserialize)]
struct MerkleProof {
    proof: MerkleProofInner,
}

#[derive(serde::Deserialize)]
struct MerkleProofInner {
    merkle_proof: Vec<String>,
    rollup_merkle_proof: Vec<String>,
    main_exit_root: String,
    rollup_exit_root: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    // Validate the dest address through Darwin's parser for an early,
    // friendly error before any RPC traffic.
    let _ = DarwinEthAddress::parse_hex(&args.dest_address)
        .ok_or_else(|| anyhow!("invalid --dest-address: {}", args.dest_address))?;
    let _ = DarwinEthAddress::parse_hex(&args.bridge_address)
        .ok_or_else(|| anyhow!("invalid --bridge-address: {}", args.bridge_address))?;

    println!("[darwin-l1-claim] L1 RPC:        {}", args.l1_rpc_url);
    println!("[darwin-l1-claim] Bridge svc:    {}", args.bridge_service_url);
    println!("[darwin-l1-claim] Bridge addr:   {}", args.bridge_address);
    println!("[darwin-l1-claim] Dest addr:     {}", args.dest_address);

    // -- 1. Poll bridge-service for a ready deposit -----------------
    let deposit = poll_for_ready_deposit(&args).await?;
    println!(
        "[darwin-l1-claim] deposit ready: cnt={} amount={} globalIndex={}",
        deposit.deposit_cnt, deposit.amount, deposit.global_index
    );

    // -- 2. Fetch the merkle proof ----------------------------------
    let proof = fetch_merkle_proof(&args, deposit.deposit_cnt, deposit.network_id).await?;
    println!(
        "[darwin-l1-claim] proof fetched: smt_local={} smt_rollup={} entries each",
        proof.proof.merkle_proof.len(),
        proof.proof.rollup_merkle_proof.len()
    );

    // -- 3. Build + submit the claimAsset tx ------------------------
    let tx_hash = submit_claim_asset(&args, &deposit, &proof).await?;
    println!();
    println!("🎯 L1 claimAsset submitted.");
    println!("   tx hash: {tx_hash}");
    println!("   bridge:  {}", args.bridge_address);
    println!();
    println!("Query the destination's wDCC balance with:");
    println!(
        "   cast call --rpc-url {} <WDCC_ADDR> 'balanceOf(address)(uint256)' {}",
        args.l1_rpc_url, args.dest_address
    );

    Ok(())
}

async fn poll_for_ready_deposit(args: &Args) -> anyhow::Result<BridgeDeposit> {
    let url = format!(
        "{}/bridges/{}",
        args.bridge_service_url.trim_end_matches('/'),
        args.dest_address
    );
    let client = reqwest::Client::new();
    let deadline =
        std::time::Instant::now() + Duration::from_secs(args.wait_timeout_s.max(POLL_INTERVAL.as_secs()));

    for attempt in 1..=POLL_MAX_ATTEMPTS {
        let resp = client
            .get(&url)
            .send()
            .await
            .context("GET /bridges/<dest> failed — is bridge-service up?")?;
        let body: BridgesResponse = resp
            .json()
            .await
            .context("could not parse /bridges response")?;

        let matched = body.deposits.into_iter().find(|d| {
            d.ready_for_claim
                && d.network_id == 1
                && d.dest_net == 0
                && args
                    .deposit_cnt
                    .map(|c| c == d.deposit_cnt)
                    .unwrap_or(true)
        });

        if let Some(dep) = matched {
            return Ok(dep);
        }

        if std::time::Instant::now() >= deadline {
            return Err(anyhow!(
                "no ready_for_claim deposit for {} after ~{}s ({} polls)",
                args.dest_address,
                args.wait_timeout_s,
                attempt
            ));
        }

        eprintln!(
            "[darwin-l1-claim] poll #{attempt}: no ready deposit yet; sleeping {}s",
            POLL_INTERVAL.as_secs()
        );
        tokio::time::sleep(POLL_INTERVAL).await;
    }

    Err(anyhow!("polling loop exited unexpectedly"))
}

async fn fetch_merkle_proof(
    args: &Args,
    deposit_cnt: u64,
    network_id: u32,
) -> anyhow::Result<MerkleProof> {
    let url = format!(
        "{}/merkle-proof?deposit_cnt={}&net_id={}",
        args.bridge_service_url.trim_end_matches('/'),
        deposit_cnt,
        network_id
    );
    let resp = reqwest::get(&url)
        .await
        .with_context(|| format!("GET {url}"))?;
    let proof: MerkleProof = resp
        .json()
        .await
        .context("could not parse /merkle-proof response")?;
    Ok(proof)
}

async fn submit_claim_asset(
    args: &Args,
    deposit: &BridgeDeposit,
    proof: &MerkleProof,
) -> anyhow::Result<String> {
    use alloy::primitives::{Address, Bytes, FixedBytes, U256};
    use alloy::providers::ProviderBuilder;
    use alloy::signers::local::PrivateKeySigner;
    use alloy::sol;

    sol! {
        #[sol(rpc)]
        interface IPolygonZkEVMBridge {
            function claimAsset(
                bytes32[32] smtProofLocalExitRoot,
                bytes32[32] smtProofRollupExitRoot,
                uint256 globalIndex,
                bytes32 mainnetExitRoot,
                bytes32 rollupExitRoot,
                uint32 originNetwork,
                address originTokenAddress,
                uint32 destinationNetwork,
                address destinationAddress,
                uint256 amount,
                bytes metadata
            ) external;
        }
    }

    let bridge_addr: Address = args
        .bridge_address
        .parse()
        .map_err(|e| anyhow!("bridge address parse: {e}"))?;
    let dest_addr: Address = deposit
        .dest_addr
        .parse()
        .map_err(|e| anyhow!("dest_addr parse: {e}"))?;
    let orig_addr: Address = deposit
        .orig_addr
        .parse()
        .map_err(|e| anyhow!("orig_addr parse: {e}"))?;
    let amount: U256 = U256::from_str_radix(deposit.amount.trim_start_matches("0x"), 10)
        .or_else(|_| U256::from_str_radix(deposit.amount.trim_start_matches("0x"), 16))
        .map_err(|e| anyhow!("amount parse: {e}"))?;
    let global_index: U256 =
        U256::from_str_radix(deposit.global_index.trim_start_matches("0x"), 10)
            .or_else(|_| U256::from_str_radix(deposit.global_index.trim_start_matches("0x"), 16))
            .map_err(|e| anyhow!("global_index parse: {e}"))?;

    let main_exit_root: FixedBytes<32> = proof
        .proof
        .main_exit_root
        .parse()
        .map_err(|e| anyhow!("main_exit_root: {e}"))?;
    let rollup_exit_root: FixedBytes<32> = proof
        .proof
        .rollup_exit_root
        .parse()
        .map_err(|e| anyhow!("rollup_exit_root: {e}"))?;

    let smt_local = pad_proof(&proof.proof.merkle_proof)?;
    let smt_rollup = pad_proof(&proof.proof.rollup_merkle_proof)?;

    let metadata = deposit
        .metadata
        .as_deref()
        .filter(|s| !s.is_empty() && *s != "0x")
        .map(|s| Bytes::from(hex::decode(s.trim_start_matches("0x")).unwrap_or_default()))
        .unwrap_or_default();

    let signer: PrivateKeySigner = args
        .funded_key
        .parse()
        .map_err(|e| anyhow!("private key: {e}"))?;
    let provider = ProviderBuilder::new()
        .wallet(signer)
        .connect_http(args.l1_rpc_url.parse().map_err(|e| anyhow!("l1 url: {e}"))?);

    let bridge = IPolygonZkEVMBridge::new(bridge_addr, &provider);
    let call = bridge.claimAsset(
        smt_local,
        smt_rollup,
        global_index,
        main_exit_root,
        rollup_exit_root,
        deposit.orig_net,
        orig_addr,
        deposit.dest_net,
        dest_addr,
        amount,
        metadata,
    );

    let pending = call
        .send()
        .await
        .map_err(|e| anyhow!("claimAsset.send: {e}"))?;
    let tx_hash = format!("{:#x}", *pending.tx_hash());
    let _receipt = pending
        .get_receipt()
        .await
        .map_err(|e| anyhow!("get_receipt: {e}"))?;
    Ok(tx_hash)
}

fn pad_proof(proof: &[String]) -> anyhow::Result<[alloy::primitives::FixedBytes<32>; 32]> {
    use alloy::primitives::FixedBytes;
    let mut out: [FixedBytes<32>; 32] = std::array::from_fn(|_| FixedBytes::<32>::default());
    for (i, entry) in proof.iter().take(32).enumerate() {
        out[i] = entry
            .parse()
            .map_err(|e| anyhow!("proof entry #{i}: {e}"))?;
    }
    Ok(out)
}
