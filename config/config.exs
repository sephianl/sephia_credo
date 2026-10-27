import Config

if config_env() == :test do
  config :ash, default_string_length_count: :mixed
end
