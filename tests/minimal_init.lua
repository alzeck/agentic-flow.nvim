vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = table.concat({ vim.fn.getcwd() .. "/?.lua", package.path }, ";")
