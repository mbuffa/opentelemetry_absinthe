defmodule OpentelemetryAbsinthe.Instrumentation do
  @moduledoc """
  Module for automatic instrumentation of Absinthe resolution.

  It works by listening to [:absinthe, :execute, :operation, :start/:stop] telemetry events,
  which are emitted by Absinthe only since v1.5; therefore it won't work on previous versions.

  (you can still call `OpentelemetryAbsinthe.Instrumentation.setup()` in your application startup
  code, it just won't do anything.)
  """
  alias Absinthe.Blueprint

  require OpenTelemetry.Tracer, as: Tracer
  require OpenTelemetry.SemanticConventions.Trace, as: Conventions
  require Logger
  require Record

  @span_ctx_fields Record.extract(:span_ctx,
                     from_lib: "opentelemetry_api/include/opentelemetry.hrl"
                   )

  Record.defrecord(:span_ctx, @span_ctx_fields)

  @default_operation_span "GraphQL Operation"
  @graphql_document Conventions.graphql_document()
  @graphql_operation_name Conventions.graphql_operation_name()
  @graphql_operation_type Conventions.graphql_operation_type()

  @default_config [
    span_name: :dynamic,
    trace_request_query: true,
    trace_request_name: true,
    trace_request_type: true,
    trace_request_variables: false,
    trace_request_selections: true,
    trace_response_result: false,
    trace_response_errors: false
  ]

  def setup(instrumentation_opts \\ []) do
    config =
      @default_config
      |> Keyword.merge(Application.get_env(:opentelemetry_absinthe, :trace_options, []))
      |> Keyword.merge(instrumentation_opts)
      |> Enum.into(%{})

    if is_binary(config.span_name) do
      Logger.warn("The opentelemetry_absinthe span_name option is deprecated and will be removed in the future")
    end

    :telemetry.attach(
      {__MODULE__, :operation_start},
      [:absinthe, :execute, :operation, :start],
      &__MODULE__.handle_operation_start/4,
      config
    )

    :telemetry.attach(
      {__MODULE__, :operation_stop},
      [:absinthe, :execute, :operation, :stop],
      &__MODULE__.handle_operation_stop/4,
      config
    )
  end

  def teardown do
    :telemetry.detach({__MODULE__, :operation_start})
    :telemetry.detach({__MODULE__, :operation_stop})
  end

  def handle_operation_start(_event_name, _measurements, metadata, config) do
    document = metadata.blueprint.input
    variables = metadata |> Map.get(:options, []) |> Keyword.get(:variables, %{})

    attributes =
      []
      |> put_if(
        config.trace_request_variables,
        {:"graphql.request.variables", Jason.encode!(variables)}
      )
      |> put_if(config.trace_request_query, {@graphql_document, document})

    save_parent_ctx()

    span_name = span_name(nil, nil, config.span_name)
    new_ctx = Tracer.start_span(span_name, %{kind: :server, attributes: attributes})

    Tracer.set_current_span(new_ctx)
  end

  def handle_operation_stop(_event_name, _measurements, data, config) do
    operation_type = get_operation_type(data)
    operation_name = get_operation_name(data)

    span_name = span_name(operation_type, operation_name, config.span_name)
    Tracer.update_name(span_name)

    errors = data.blueprint.result[:errors]

    result_attributes =
      []
      |> put_if(
        config.trace_request_type,
        {@graphql_operation_type, operation_type}
      )
      |> put_if(
        config.trace_request_name,
        {@graphql_operation_name, operation_name}
      )
      |> put_if(
        config.trace_response_result,
        {:"graphql.response.result", Jason.encode!(data.blueprint.result)}
      )
      |> put_if(
        config.trace_response_errors,
        {:"graphql.response.errors", Jason.encode!(errors)}
      )
      |> put_if(
        config.trace_request_selections,
        fn -> {:"graphql.request.selections", data |> get_graphql_selections() |> Jason.encode!()} end
      )

    set_status(errors)

    Tracer.set_attributes(result_attributes)
    Tracer.end_span()

    restore_parent_ctx()
    :ok
  end

  defp get_graphql_selections(%{blueprint: %Blueprint{} = blueprint}) do
    blueprint
    |> Blueprint.current_operation()
    |> Kernel.||(%{})
    |> Map.get(:selections, [])
    |> Enum.map(& &1.name)
    |> Enum.uniq()
  end

  def default_config do
    @default_config
  end

  defp get_operation_type(%{blueprint: %Blueprint{} = blueprint}) do
    blueprint |> Absinthe.Blueprint.current_operation() |> Kernel.||(%{}) |> Map.get(:type)
  end

  defp get_operation_name(%{blueprint: %Blueprint{} = blueprint}) do
    blueprint |> Absinthe.Blueprint.current_operation() |> Kernel.||(%{}) |> Map.get(:name)
  end

  defp span_name(_, _, name) when is_binary(name), do: name
  defp span_name(nil, _, _), do: @default_operation_span
  defp span_name(op_type, nil, _), do: Atom.to_string(op_type)
  defp span_name(op_type, op_name, _), do: "#{Atom.to_string(op_type)} #{op_name}"

  # Surprisingly, that doesn't seem to by anything in the stdlib to conditionally
  # put stuff in a list / keyword list.
  # This snippet is approved by José himself:
  # https://elixirforum.com/t/creating-list-adding-elements-on-specific-conditions/6295/4?u=learts
  defp put_if(list, false, _), do: list
  defp put_if(list, true, value_fn) when is_function(value_fn), do: [value_fn.() | list]
  defp put_if(list, true, value), do: [value | list]

  # taken from https://github.com/opentelemetry-beam/opentelemetry_plug/blob/82206fb09fbeb9ffa2f167a5f58ea943c117c003/lib/opentelemetry_plug.ex#L186
  @ctx_key {__MODULE__, :parent_ctx}
  defp save_parent_ctx do
    ctx = Tracer.current_span_ctx()
    Process.put(@ctx_key, ctx)
  end

  defp restore_parent_ctx do
    ctx = Process.get(@ctx_key, :undefined)
    Process.delete(@ctx_key)
    Tracer.set_current_span(ctx)
  end

  # set status as `:error` in case of errors in the graphql response
  defp set_status(nil), do: :ok
  defp set_status([]), do: :ok
  defp set_status(_errors), do: Tracer.set_status(OpenTelemetry.status(:error, ""))
end
