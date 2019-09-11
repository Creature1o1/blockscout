defmodule Indexer.Temporary.InternalTransactionsBlockNumber do
  @moduledoc """
  Looks for a table `blocks_to_invalidate_wrong_int_txs_collation` specifing
  the `number` of blocks that need to be refetched and removes their consensus.
  """

  use Indexer.Fetcher

  require Logger

  import Ecto.Query

  alias Ecto.Multi
  alias Explorer.Chain.Block
  alias Explorer.Repo
  alias Indexer.BufferedTask
  alias Indexer.Temporary.InternalTransactionsBlockNumber

  @behaviour BufferedTask

  @defaults [
    flush_interval: :timer.seconds(3),
    max_batch_size: 50,
    max_concurrency: 2,
    task_supervisor: Indexer.Temporary.InternalTransactionsBlockNumber.TaskSupervisor,
    metadata: [fetcher: :internal_transactions_block_number]
  ]

  @doc false
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  def child_spec([init_options, gen_server_options]) do
    merged_init_opts =
      @defaults
      |> Keyword.merge(init_options)
      |> Keyword.put(:state, {})

    Supervisor.child_spec({BufferedTask, [{__MODULE__, merged_init_opts}, gen_server_options]}, id: __MODULE__)
  end

  @impl BufferedTask
  def init(initial, reducer, _) do
    query =
      from(
        s in InternalTransactionsBlockNumber.Schema,
        where: is_nil(s.refetched) or not s.refetched,
        # goes from latest to newest
        order_by: [desc: s.block_number],
        select: s.block_number
      )

    {:ok, final} = Repo.stream_reduce(query, initial, &reducer.(&1, &2))

    final
  rescue
    postgrex_error in Postgrex.Error ->
      # if the table does not exist it just does no work
      case postgrex_error do
        %{postgres: %{code: :undefined_table}} -> {0, []}
        _ -> raise postgrex_error
      end
  end

  @impl BufferedTask
  def run(block_numbers, _) do
    # Enforce ShareLocks tables order (see docs: sharelocks.md)
    multi =
      Multi.new()
      |> Multi.run(:remove_block_consensus, fn repo, _ ->
        query =
          from(
            block in Block,
            where: block.number in ^block_numbers,
            # Enforce Block ShareLocks order (see docs: sharelocks.md)
            order_by: [asc: block.hash],
            lock: "FOR UPDATE"
          )

        {_num, result} =
          repo.update_all(
            from(b in Block, join: s in subquery(query), on: b.hash == s.hash),
            set: [consensus: false]
          )

        {:ok, result}
      end)
      |> Multi.run(:update_schema_entries, fn repo, _ ->
        query =
          from(
            s in InternalTransactionsBlockNumber.Schema,
            order_by: [desc: s.block_number],
            lock: "FOR UPDATE"
          )

        {num, _res} =
          repo.update_all(
            from(dtt in InternalTransactionsBlockNumber.Schema,
              join: s in subquery(query),
              on: dtt.block_number == s.block_number
            ),
            set: [refetched: true]
          )

        {:ok, num}
      end)

    try do
      multi
      |> Repo.transaction()
      |> case do
        {:ok, _res} ->
          :ok

        {:error, error} ->
          Logger.error(fn ->
            ["Error while handling internal_transactions with wrong block number: ", inspect(error)]
          end)

          {:retry, block_numbers}
      end
    rescue
      postgrex_error in Postgrex.Error ->
        Logger.error(fn ->
          ["Error while handling internal_transactions with wrong block number: ", inspect(postgrex_error)]
        end)

        {:retry, block_numbers}
    end
  end

  defmodule Schema do
    @moduledoc """
    Schema for the table `blocks_to_invalidate_wrong_int_txs_collation`, used by the refetcher
    """

    use Explorer.Schema

    @type t :: %__MODULE__{
            block_number: Block.block_number(),
            refetched: boolean() | nil
          }

    @primary_key false
    schema "blocks_to_invalidate_wrong_int_txs_collation" do
      field(:block_number, :integer)
      field(:refetched, :boolean)
    end

    def changeset(%__MODULE__{} = with_wrong_int_txs, attrs) do
      with_wrong_int_txs
      |> cast(attrs, [:block_number, :refetched])
      |> validate_required(:block_number)
    end
  end
end
