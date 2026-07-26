# Circuit diagrams

The Typst sources in this directory use
[`zap`](https://typst.app/universe/package/zap) 0.6.0. Render the documentation
assets from the repository root with:

```sh
for source in docs/diagrams/*.typ; do
    name=${source##*/}
    typst compile --format svg "$source" "docs/src/assets/circuits/${name%.typ}.svg"
done
```

For visual review, render a temporary PNG at a useful pixel density:

```sh
typst compile --format png --ppi 180 docs/diagrams/rc-low-pass.typ /tmp/rc-low-pass.png
```

Commit the SVG outputs alongside their Typst sources so building the Julia
documentation does not require Typst or network access.
