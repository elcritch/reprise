defmodule Reprise.Runner do
  require Logger

  @moduledoc """
  Module discovery and reloading.

  The main entry point is `go/2` function.
  """

  @type time :: :calendar.datetime
  @type path :: [String.t]
  @type beam :: String.t

  @spec load_path(Regex.t) :: path
  def load_path(pattern \\ ~r[/_build/]) do
    for d <- :code.get_path,
        d = Path.expand(d),
        Regex.match?(pattern, d),
    do: d
  end

  @spec iterate_beams(path) :: [beam]
  def iterate_beams(load_path) do
    for d <- load_path, File.dir?(d) do
      for f <- File.ls!(d), Path.extname(f)==".beam", do: Path.join(d,f)
    end
    |> List.flatten
  end

  @doc """
  Returns all beam files belonging to the build of current project.
  """
  @spec beams() :: [beam]
  def beams(), do: load_path |> iterate_beams

  @doc """
  Returns pairs of beam files and modules which are loaded
  and belong to the build of current project.
  """
  @spec beam_modules([beam]) :: [{beam, module}]
  def beam_modules(beams \\ __MODULE__.beams) do
    beamset = beams |> Enum.into(HashSet.new)
    for {m,f} <- :code.all_loaded,
      is_list(f),
      f = Path.expand(f),
      Set.member?(beamset, f),
      do: {f,m}
  end

  @doc "Reloads a single module."
  @spec reload(module) :: {:module, module} | {:error, atom}
  def reload(module) do
    :code.purge(module)
    module_obj = :code.load_file(module)

    case :code.get_object_code(module) do
      :error -> :error
      { module, binary, filename } = code_obj ->
        unless Regex.match?(~r[/consolidated/], to_string filename) do
          :gproc.send({:p, :l, :reprise}, {:remote_reload, code_obj})
        end
    end

    module_obj
  end

  @doc "Remotely reloads a single module."
  def remote_reload({ module, binary, filename}) do
    IO.puts("Remotly reloading module: #{inspect module} @ file: #{filename}")
    :code.purge(module)
    :code.load_binary( module, filename, binary )
  end

  @doc """
  Attempts to reload all modules which belong to the current mix project
  and have changed between given time frames.

  If there were any and they reloaded successfully, prints a summary
  via `Logger.info/1`.

  Modules whose reload errored are silently ignored.

  Returns `:ok` if there were any modules successfully reloaded
  or `nil` when there were none.
  """
  @spec go(time, time) :: :ok | nil
  def go(from, to) do
    modules = for {f,m} <- beam_modules do
      case File.stat(f, time: :local) do
        {:ok, %File.Stat{mtime: mtime}} when mtime >= from and mtime < to ->
          case reload(m) do
            {:module, m} -> {:reloaded, m}
            {:error, _} -> {:load_error, m}
          end
        {:ok, _} -> {:unmodified, m}
        {:error, _} -> {:fstat_error, m}
      end
    end
    reloaded = for {:reloaded, m} <- modules, do: m
    unless reloaded == [], do:
      Logger.info("Reloaded modules: #{inspect reloaded}")
  end
end
