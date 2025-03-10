### Modularity:
The following phases which are generic to basically all existing 2nix solutions:
  - parsing project metadata
  - resolving/locking dependencies (not always required)
  - fetching sources
  - building/installing packages

... should be separated from each other with well defined interfaces.

This will allow for free composition of different approaches for these phases.
The user should be able to freely choose between:
  - input metadata formats (eg. lock file formats)
  - metadata fetching/translation strategies: IFD vs. in-tree
  - source fetching strategies: granular fetching vs fetching via single large FOD to minimize expression file size
  - installation strategies: build dependencies individually vs inside a single derivation.

### Customizability
Every Phase mentioned in the previous section should be customizable at a high degree via override functions. Practical examples:
  - Inject extra requirements/dependencies
  - fetch sources from alternative locations
  - replace or modify sources
  - customize the build/installation procedure

### Maintainability
Due to the modular architecture with strict interfaces, contributers can add support for new lock-file formats or new strategies for fetching, building, installing more easily.

### Compatibility
Depending on where the nix code is used, different approaches are desired or discouraged. While IFD might be desired for some out of tree projects to achieve simplified UX, it is strictly prohibited in nixpkgs due to nix/hydra limitations.
All solutions which follow the dream2nix specification will be compatible with both approaches without having to re-invent the tool.

### Code de-duplication
Common problems that apply to many 2nix solutions can be solved once by the framework. Examples:
  - handling cyclic dependencies
  - handling sources from various origins (http, git, local, ...)
  - generate nixpkgs/hydra friendly output (no IFD)
  - good user interface

### Code de-duplication in nixpkgs
Essential components like package update scripts or fetching and override logic are provided by the dream2nix framework and are stored only once in the source tree instead of several times.

### Risk free opt-in FOD fetching
Optionally, to save more storage space, individual hashes for source can be ommited and a single large FOD used instead.
Due to a unified minimalistic fetching layer the risk of FOD hash breakages should be very low.

### Common UI across many 2nix solutions
2nix solutions which follow the dream2nix framework will have a unified UI for workflows like project initialization or code generation. This will allow quicker onboarding of new users by providing familiar workflows across different build systems.

### Reduced effort to develop new 2nix solutions
Since the framework already solves common problems and provides an interface for integrating new build systems, developers will have an easier time creating their next 2nix solution.

### Architecture
The general architecture should consist of these components:  
`Input -> Translation -> Generic Lock -> Fetching -> Building`

```
┌───────┐
│ Input │◄── Arbitrary
└────┬──┘                 URLs + Metadata containing Build instructions
     │   ┌──────────┐     in standardized minimalistic form (json)
     └──►│Translator│        │
         └───────┬──┘        ▼
           ▲     │   ┌────────────┐
           │     └──►│Generic Lock│
           │         └─────────┬──┘
  - pure-nix                   │   ┌────────┐
  - IFD / recursive-nix        ├──►│Fetcher │◄── Same across all
  - impure (external)          │   └────────┘    languages/frameworks
                               │       ▼
                               │   ┌────────┐
                               └──►│Builder │◄── Reads extra metadata
                                   └────────┘    from generic lock
```

Input:
- can consist of:
  - requirement contstraints
  - requirement files
  - lock-files
  - project's source tree

Translator:
  - read input and generate generic lock format containing:
    - URLs + hashes of sources
    - metadata for building
  - different strategies can be used:
    - `pure-nix`: translate input by using the nix language only
    - `IFD/recursive`: translate using a nix build
    - `external`: translate using an external tool which resolves against an online package index
  - for more information about translators and how nixpkgs compatibility is guaranteed, check [./translators.md](/docs/translators.md)

Generic Lock (standardized format):
  - Produced by `Translator`. Contains URLs + hashes for sources and metadata relevant for building.
  - The contained format for sources and dependency relations is independent of the build system. Fetching works always the same.
  - The metadata also contains build system specific attributes as individual approaches are required here. A specific builder for the individual build system will later read this metadata and transform it into nix derivations.
  - It is not relevant which steps/strategies have been taken to create this lock. From this point on, there are no impurities. This format will contain everything necessary for a fully reproducible build.
  - This format can always be put into nixpkgs, not requiring any IFD (given the nix code for the builder exists within nixpkgs).
  - In case of a pure-nix translator, the generic lock data can be generated on the fly and passed directly to the builder, preventing unnecessary usage of IFD.

Fetcher:
  - Since a generic lock was produced in the previous step, the fetching layer can be the same across all build systems.

Builder:
  - Receives sources from fetcher and metadata produced by the translator.
  - The builder transforms the metadata into nix derivation(s).
  - Strictly separating the builder from previous phases allows:
    - switching between different build strategies or upgrading the builder without having to re-run the translator each time.
    - reducing code duplication if a project contains multiple packages built via dream2nix.


### Example (walk through the phases)
#### python project with poetry.lock
As an example we package a python project that uses poetry for dependency management.
Potery uses `pyproject.toml` and `poetry.lock` to lock dependencies
- Input: pyproject.toml, poetry.lock (toml)
- Translator: written in pure nix, reading the toml input and generating the generic lock format
- Generic Lock (for explanatory purposes dumped to json and commented):
    ```json5
    {
      // generic lock format version
      "version": 1,

      // format for sources is always the same (not specific to python)
      "sources": {
        "requests": {
          "type": "tarball",
          "url": "https://download.pypi.org/requests/2.28.0",
          "hash": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        },
        "certifi": {
          "type": "github",
          "owner": "certifi",
          "repo": "python-certifi",
          "hash": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        }
      },

      // generic metadata (not specific to python)
      "_generic": {

        // this indicates which builder must be used
        "subsystem": "python",

        // translator which generated this file
        // (not relevant for building)
        "producedBy": "translator-poetry-1",

        // dependency graph of the packages
        "dependencies": {
          "requests": [
            "certifi"
          ]
        }
      },

      // all fields inside 'subsystem' are specific to
      // the selected subsystem (python)
      "_subsystem": {

        // tell the python builder how the inputs must be handled
        "sourceFormats": {
          "requests": "sdist",  // triggers build instructions for sdist
          "certifi": "wheel"    // triggers build instructions for wheel
        }
      }
    }
    ```
- This lock data can now either:
  - be dumped to a .json file and committed to a repo
  - passed directly to the fetching/building layer
- the fetcher will only read the sources section and translate it to standard fetcher calls.
- the building layer will read the "subsystem" attribute and select the python builder for building.
- the python builder will read all information from "subsystem" and translate the data to a final derivation.

Notes on IFD, FOD and code generation:  
- No matter which type of translator is used, it is always possible to export the generic lock to a file, which can later be evaluated without using IFD or FOD, similar to current nix code generators, just with a standardized format.
- If the translator supports IFD or is written in pure nix, it is optional to the user to skip exporting the generic lock and instead evaluate everything on the fly.
