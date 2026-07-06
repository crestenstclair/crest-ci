import Config

# Minimal, environment-agnostic logging config. No component in this
# umbrella binds a port or dials a network endpoint at boot — every
# listener/client is started explicitly by tests or the demo task — so
# there is nothing environment-coupled to configure here.
config :logger, level: if(config_env() == :test, do: :warning, else: :info)
