# fastlane (tjena!chat)

Publishes the Android APK as a GitHub release, which is what Obtainium and the
website install from. Run from `android/`:

```bash
sudo apt install ruby-dev                        # once: Ruby headers for native gems
gem install --user-install bundler               # once
export PATH="$HOME/.local/share/gem/ruby/3.0.0/bin:$PATH"   # bundler (add to ~/.bashrc)
bundle config set --local path vendor/bundle    # once: gems stay in this folder
bundle install                                  # once
bundle exec fastlane bump                       # new version name (+ build number)
# write metadata/android/en-US/changelogs/<build>.txt, commit, push
GITHUB_TOKEN=... bundle exec fastlane release   # build + publish v<version>
```

Lanes: `bump [type:minor|major]`, `build`, `github [draft:true]`, `release`.
Every published release needs a new version name (Obtainium compares the tag
with the installed version). The APK must always be signed with the same key
(`android/key.properties`), or installed apps can't update.

`metadata/` is the store listing (fastlane / F-Droid layout, linked from the
repo root as `fastlane/metadata`).
