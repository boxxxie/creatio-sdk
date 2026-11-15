# Exclude live server tests by default to protect the live Creatio instance
ExUnit.start(exclude: [:live])

ex_unit_config = ExUnit.configuration()

load_dotenv? =
  :live in List.wrap(ex_unit_config[:only]) or
    :live in List.wrap(ex_unit_config[:include]) or
    System.get_env("CREATIO_LOAD_DOTENV") == "true"

env_file = Path.expand("../.env", __DIR__)

if load_dotenv? and File.exists?(env_file) do
  env_file
  |> File.read!()
  |> String.split(["\r\n", "\n"], trim: true)
  |> Enum.each(fn line ->
    line = String.trim(line)

    if not (String.starts_with?(line, "#") or line == "") do
      case String.split(line, "=", parts: 2) do
        [key, val] ->
          clean_val = val |> String.trim() |> String.trim("\"") |> String.trim("'")
          System.put_env(String.trim(key), clean_val)

        _ ->
          :ok
      end
    end
  end)
end
