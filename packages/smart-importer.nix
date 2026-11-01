# smart_importer — scikit-learn predictions for Beancount entries (MIT,
# github.com/beancount/smart_importer). nixpkgs has no package for it (checked 2026-11-01 on
# this flake's pin), so this builds the published wheel.
#
# The WHEEL, not the sdist: the project is pure Python (`py3-none-any`), so the wheel is the
# exact artefact PyPI serves and needs no build backend. Its sha256 was checked against PyPI's
# published digest for 1.2 (73a925f8…eaa8) before pinning.
#
# Consumer: the beancount plugin's `suggest` (kattakath/skills), which uses EntryPredictor as a
# library to suggest Plaid categories for flagged entries. Pulled into local.beancount's
# interpreter only when `local.beancount.smartImporter` is on, so scikit-learn and numpy do not
# ride along by default.
#
# OFF on every host, deliberately (2026-11-01). Measured on a real journal: 92.9% on a holdout
# of rule-labelled entries, but a spot check of the entries that actually need review found
# about 3 in 15 right — the model falls back to its largest class on merchants it has never
# seen. Review works through merchant groups turned into rules instead; this stays available
# as an opt-in tool.
{
  lib,
  buildPythonPackage,
  fetchPypi,
  beancount,
  beangulp,
  scikit-learn,
  numpy,
  typing-extensions,
}:
buildPythonPackage rec {
  pname = "smart_importer";
  version = "1.2";
  format = "wheel";

  src = fetchPypi {
    inherit pname version format;
    dist = "py3";
    python = "py3";
    hash = "sha256-c6kl+PXE70Rw8wDpzkeifi41kRy6X+TB9qoubQKz6qg=";
  };

  dependencies = [
    beancount
    beangulp
    scikit-learn
    numpy
    typing-extensions
  ];

  pythonImportsCheck = [ "smart_importer" ];

  meta = {
    description = "Augment Beancount importers with machine learning";
    homepage = "https://github.com/beancount/smart_importer";
    license = lib.licenses.mit;
  };
}
