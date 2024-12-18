---
title: Installation
description: Build locally Bonzai and start beginning your first project with it.
sidebar:
  order: 0
---

To get started with Bonzai, you first need to install it. At the time of writing, Bonzai is only available by cloning the repository and running it locally.

**Note:** Bonzai is still in development and is not yet available as a stable release. If you encounter any issues, please report them on the [GitHub repository](https://github.com/thomasvergne/bonzai). Furthermore, the language might be only available for **suitable Unix-based systems**.

## Dependencies

Before you can install Bonzai, you need to have the following dependencies installed:

- **Python 3** in order to run the build script that builds the programming language automatically.
- **Haskell** with GHC 2021
- **XMake** with a suitable version of the C compiler

## Installation

To install Bonzai, follow these steps:

1. Clone the repository:

    ```bash
    git clone https://github.com/thomasvergne/bonzai
    cd bonzai
    ```

2. Run the build script

    ```bash
    python3 scripts/build.py
    ```

3. Export the Bonzai binary path to your PATH and the Bonzai folder path to BONZAI_PATH
  
    ```bash
    export BONZAI_PATH="/path/to/bonzai"
    export PATH="/path/to/bonzai/bin:$PATH"
    ``` 

4. You're all set! You can now run Bonzai by typing `bonzaic` in your terminal.
