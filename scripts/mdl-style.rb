# House markdownlint style, copied from the adr skill's HOUSE_MDL_STYLE so lintorama and `adr.py lint`
# agree. mdl `all`, minus whitespace and line-length (swift-format and editorconfig own those), minus the
# rules that fight Keep-a-Changelog files and frontmatter-led agent files.
all
exclude_tag :whitespace
exclude_tag :line_length
exclude_rule 'MD006'
exclude_rule 'MD007'
exclude_rule 'MD033'
exclude_rule 'MD034'
exclude_rule 'MD040'
exclude_rule 'MD041'
exclude_rule 'MD047'
exclude_rule 'MD002'
exclude_rule 'MD029'
rule 'MD024', :allow_different_nesting => true
