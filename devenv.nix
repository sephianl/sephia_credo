{
  pkgs,
  config,
  ...
}:

{
  cachix.enable = false;

  languages.elixir = {
    enable = true;
    package = pkgs.elixir_1_19;
  };

  git-hooks.hooks = {
    mix-format = {
      enable = !config.devenv.isTesting;
      name = "mix-format";
      files = ".ex[s]?$";
      entry = "mix format";
    };
    mix-check = {
      enable = !config.devenv.isTesting;
      name = "mix-check";
      entry = "mix check --no-retry";
      pass_filenames = false;
      stages = [ "pre-commit" ];
      files = ".ex[s]?$";
    };
  };
}
