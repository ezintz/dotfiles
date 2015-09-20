# dotfiles

[dotfiles](https://dotfiles.github.io/) gives you the possibility to customize your system. These are mine.

## Prerequisites

Please make sure that you have at least [Zsh](http://www.zsh.org/) 4.3.17 or higher installed on your system if you would like to run the automated installation and make use of [prezto](https://github.com/ezintz/prezto).

## What's inside my dotfiles?

Obviously [prezto](https://github.com/sorin-ionescu/prezto) which is an awesome configuration framework for [Zsh](http://www.zsh.org/). Please note that I adjusted the paths to work with this repository.

Default set of settings for Mac OS X which are gratuitously stolen from [@mathiasbynens](https://mths.be/dotfiles) and customized to my needs.

### Homebrew formulae (only Mac OS X)

* [coreutils](http://www.gnu.org/software/coreutils/): The GNU Core Utilities are the basic file, shell and text manipulation utilities of the GNU operating system.
* [ack](http://beyondgrep.com/): Tool like grep, optimized for programmers.
* [curl](http://curl.haxx.se/): Tool for client-side URL transfers.
* [flow](http://flowtype.org/): Adds static typing to JavaScript to improve developer productivity and code quality.
* [fortune](https://en.wikipedia.org/wiki/Fortune_(Unix): Simple program that displays a pseudorandom message from a database of quotation.
* [git](http://git-scm.com/): Distributed version control system.
* [git-extras](https://github.com/tj/git-extras): Some extras for `git`
* [git-flow](https://github.com/nvie/gitflow): Extension to provide high-level repository operations.
* [git-lfs](https://github.com/github/git-lfs): Extension for versioning large files
* [node](http://nodejs.org/): Node.js is a platform built on [Chrome's JavaScript runtime](https://code.google.com/p/v8/) for easily building fast, scalable applications.
* [tmux](https://tmux.github.io/): Terminal multiplexer like [screen](https://www.gnu.org/software/screen/).
* [watchman](https://facebook.github.io/watchman/): File watching service.
* [wget](http://www.gnu.org/software/wget/): GNU Wget is a free software package for retrieving files.

### npm packages

* [n](https://github.com/visionmedia/n): Tool for Node.js version management.
* [babel](https://babeljs.io/): JavaScript compiler to use next generation JavaScript, today.
* [gulp](http://gulpjs.com/): Steaming build system that automate and enhance your workflow.

### Python packages

* [Pygments](http://pygments.org/): Generic syntax highlighter.

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/ezintz/dotfiles/master/bin/dotfiles | /usr/bin/env zsh
```

## Usage

Just do whatever you did before. In addition you also got a new command `dotfiles` that you can use.

```sh
dotfiles --no-configuration \ # Do not apply any configuration
  --no-packages \ # Do not install/update packages
  --no-sync \ # Do not sync with repository
  --no-links # Do not create symbolic links
```

# Credits

To all the authors of the tools that are used by dotfiles and all the other dotfiles repositories.

# License

Non-third party files are licensed under the WTFPL; terms and conditions can be
found at: [http://www.wtfpl.net/about/](http://www.wtfpl.net/about/)
