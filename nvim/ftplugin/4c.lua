-- Ftplugin for 4C, the C-flavored language,
-- used in the 4B Fantasy Box.

-- Use // for comments in 4C.
vim.bo.commentstring = '// %s'

-- 4C has no fixed-width instruction columns like 4A;
-- indent with 2 spaces, as in the examples.
vim.bo.expandtab = true
vim.bo.tabstop = 4
vim.bo.shiftwidth = 2
