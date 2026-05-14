//! Darwin-flavoured bridge-out CLI — submits a real B2AGG note from a
//! Miden wallet to the AggLayer bridge account, carrying a Darwin
//! basket-token asset out to Ethereum.
//!
//! Replaces the inline `bridge-out-tool` invocation in
//! `darwin-infra/scripts/darwin-bridge-out-dcc.sh` with a Rust binary
//! that consumes Darwin's own `B2AggBuilder` typed inputs.  Decoupled
//! from the upstream container so the SDK can drive bridge-out
//! against any miden-client store (local stack or public testnet
//! bridge once it's live).
//!
//! Wire it up by feeding it the mirror faucet id from
//! `darwin-bridge-register-dcc.sh`:
//!
//!     cargo run -p darwin-bridge-adapter --features=client \
//!         --bin darwin_bridge_out -- \
//!         --store-dir ~/.miden \
//!         --node-url http://localhost:57291 \
//!         --wallet-id <WALLET_HEX> \
//!         --bridge-id <BRIDGE_HEX> \
//!         --faucet-id <DCC_MIRROR_FAUCET_HEX> \
//!         --amount 100 \
//!         --dest-address 0x71562b71999873DB5b286dF957af199Ec94617F7
//!
//! `--wallet-id` and `--bridge-id` come from miden-agglayer's
//! `bridge_accounts.toml` (located at
//! `/var/lib/miden-agglayer-service/bridge_accounts.toml` inside the
//! upstream container — `cat` it via `docker exec` before running).

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{anyhow, Context};
use clap::Parser;
use miden_agglayer::B2AggNote;
use miden_agglayer::EthAddress as AggLayerEthAddress;
use miden_client::asset::{Asset, FungibleAsset};
use miden_client::builder::ClientBuilder;
use miden_client::keystore::FilesystemKeyStore;
use miden_client::note::NoteAssets;
use miden_client::transaction::TransactionRequestBuilder;
use miden_client_sqlite_store::SqliteStore;
use miden_protocol::account::AccountId;

#[derive(Parser, Debug)]
#[command(version, about = "Darwin-flavoured B2AGG bridge-out CLI")]
struct Args {
    /// miden-client store directory (contains `store.sqlite3` and `keystore/`)
    #[arg(long)]
    store_dir: PathBuf,

    /// Miden node gRPC URL
    #[arg(long, default_value = "http://localhost:57291")]
    node_url: String,

    /// Sender wallet account id (hex or bech32)
    #[arg(long)]
    wallet_id: String,

    /// AggLayer bridge account id on Miden (hex or bech32)
    #[arg(long)]
    bridge_id: String,

    /// Asset faucet id to bridge out (Darwin basket token or its
    /// AggLayer mirror faucet)
    #[arg(long)]
    faucet_id: String,

    /// Amount in faucet base units
    #[arg(long)]
    amount: u64,

    /// L1 destination address (0x-prefixed hex, 20 bytes)
    #[arg(long)]
    dest_address: String,

    /// Destination AggLayer network id (0 = Ethereum L1)
    #[arg(long, default_value_t = 0u32)]
    dest_network: u32,
}

fn parse_account_id(s: &str) -> anyhow::Result<AccountId> {
    if let Ok(id) = AccountId::from_hex(s) {
        return Ok(id);
    }
    if let Ok((_, id)) = AccountId::from_bech32(s) {
        return Ok(id);
    }
    Err(anyhow!("cannot parse account ID: {s}"))
}

fn parse_endpoint(url: &str) -> anyhow::Result<miden_client::rpc::Endpoint> {
    // Accept "testnet" / "devnet" / "localhost" shortcuts, or a full URL.
    match url {
        "testnet" => Ok(miden_client::rpc::Endpoint::testnet()),
        "devnet" => Ok(miden_client::rpc::Endpoint::devnet()),
        "localhost" => Ok(miden_client::rpc::Endpoint::localhost()),
        other => {
            let parsed = url::Url::parse(other)
                .map_err(|e| anyhow!("invalid --node-url {other}: {e}"))?;
            let protocol = parsed.scheme().to_string();
            let host = parsed
                .host_str()
                .ok_or_else(|| anyhow!("--node-url missing host: {other}"))?
                .to_string();
            let port = parsed.port();
            Ok(miden_client::rpc::Endpoint::new(protocol, host, port))
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args = Args::parse();

    let wallet_id = parse_account_id(&args.wallet_id).context("--wallet-id")?;
    let bridge_id = parse_account_id(&args.bridge_id).context("--bridge-id")?;
    let faucet_id = parse_account_id(&args.faucet_id).context("--faucet-id")?;

    // Validate the L1 destination through Darwin's own EthAddress
    // first — gives a clean error before pulling miden-agglayer's
    // parser. Then convert to the upstream type for the B2AGG note.
    let darwin_dest = darwin_bridge_adapter::EthAddress::parse_hex(&args.dest_address)
        .ok_or_else(|| anyhow!("invalid --dest-address: {}", args.dest_address))?;
    let agglayer_dest = AggLayerEthAddress::new(darwin_dest.as_bytes());

    // M1 only supports Ethereum L1 as the destination network.
    if args.dest_network != 0 {
        anyhow::bail!(
            "unsupported destination network: {} (M1 supports 0 / Ethereum L1)",
            args.dest_network
        );
    }

    println!("[darwin-bridge-out] wallet:  {wallet_id}");
    println!("[darwin-bridge-out] bridge:  {bridge_id}");
    println!("[darwin-bridge-out] faucet:  {faucet_id}");
    println!("[darwin-bridge-out] amount:  {} base units", args.amount);
    println!(
        "[darwin-bridge-out] dest:    {} (network {})",
        args.dest_address, args.dest_network
    );

    let store_path = args.store_dir.join("store.sqlite3");
    let keystore_path = args.store_dir.join("keystore");
    if !store_path.exists() {
        return Err(anyhow!("store missing at {}", store_path.display()));
    }
    if !keystore_path.exists() {
        return Err(anyhow!("keystore missing at {}", keystore_path.display()));
    }

    println!("[darwin-bridge-out] building miden-client…");
    let store = SqliteStore::new(store_path).await?;
    let endpoint = parse_endpoint(&args.node_url)?;
    let mut client = ClientBuilder::<FilesystemKeyStore>::new()
        .grpc_client(&endpoint, None)
        .store(Arc::new(store))
        .filesystem_keystore(keystore_path)?
        .build()
        .await?;

    println!("[darwin-bridge-out] syncing state…");
    client
        .sync_state()
        .await
        .map_err(|e| anyhow!("sync: {e}"))?;

    // Balance check.
    let balance = client
        .account_reader(wallet_id)
        .get_balance(faucet_id)
        .await
        .map_err(|e| anyhow!("get_balance: {e}"))?;
    println!("[darwin-bridge-out] wallet balance: {balance}");
    if balance < args.amount {
        return Err(anyhow!(
            "insufficient balance: have {balance}, need {}",
            args.amount
        ));
    }

    // Build the B2AGG note through miden-agglayer's canonical builder.
    let asset: Asset = FungibleAsset::new(faucet_id, args.amount)
        .map_err(|e| anyhow!("invalid asset: {e}"))?
        .into();
    let note_assets = NoteAssets::new(vec![asset]).map_err(|e| anyhow!("note assets: {e}"))?;

    let b2agg_note = B2AggNote::create(
        args.dest_network,
        agglayer_dest,
        note_assets,
        bridge_id,
        wallet_id,
        client.rng(),
    )
    .map_err(|e| anyhow!("B2AggNote::create: {e}"))?;

    println!(
        "[darwin-bridge-out] B2AGG note built. id: {}",
        b2agg_note.id()
    );

    // Re-import the bridge account so we have the latest asset tree.
    if let Err(e) = client.import_account_by_id(bridge_id).await {
        eprintln!("[darwin-bridge-out] bridge re-import warning: {e}");
    }
    client
        .sync_state()
        .await
        .map_err(|e| anyhow!("pre-submit sync: {e}"))?;

    let tx_request = TransactionRequestBuilder::new()
        .own_output_notes(vec![b2agg_note.clone()])
        .build()
        .map_err(|e| anyhow!("tx request: {e}"))?;

    println!("[darwin-bridge-out] submitting transaction…");
    let tx_result = client
        .execute_transaction(wallet_id, tx_request)
        .await
        .map_err(|e| anyhow!("execute: {e}"))?;
    let prover = client.prover();
    let proven = client
        .prove_transaction_with(&tx_result, prover)
        .await
        .map_err(|e| anyhow!("prove: {e}"))?;
    let height = client
        .submit_proven_transaction(proven, &tx_result)
        .await
        .map_err(|e| anyhow!("submit: {e}"))?;
    client
        .apply_transaction(&tx_result, height)
        .await
        .map_err(|e| anyhow!("apply: {e}"))?;

    println!();
    println!("🎯 B2AGG note submitted on Miden.");
    println!("   note id:        {}", b2agg_note.id());
    println!("   tx id:          {}", tx_result.executed_transaction().id());
    println!("   block height:   {height}");
    println!();
    println!("Next: wait for bridge-service to surface the deposit as");
    println!("ready_for_claim, then claim on L1 to mint the wrapped");
    println!("token (wDCC) into --dest-address.");

    Ok(())
}
