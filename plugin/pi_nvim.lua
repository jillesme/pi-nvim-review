if vim.g.loaded_nvim_pi_comment then
  return
end
vim.g.loaded_nvim_pi_comment = true

local function create_command(name, callback, opts)
  if vim.fn.exists(":" .. name) ~= 0 then
    vim.schedule(function()
      vim.notify("pi-nvim: cannot create :" .. name .. " because it already exists", vim.log.levels.ERROR)
    end)
    return
  end
  opts.force = false
  vim.api.nvim_create_user_command(name, callback, opts)
end

create_command("Pi", function()
  require("pi_nvim").select_session()
end, { desc = "Select a live Pi review session" })

create_command("PiAnnotate", function(args)
  require("pi_nvim").annotate(args.line1, args.line2)
end, { desc = "Add a Pi comment to a line range", range = true })

create_command("PiSubmit", function()
  require("pi_nvim").submit()
end, { desc = "Submit pending comments to the active Pi session" })

create_command("PiClear", function()
  require("pi_nvim").clear()
end, { desc = "Clear pending Pi comments" })

vim.keymap.set("n", "<Plug>(PiAnnotate)", "<Cmd>PiAnnotate<CR>", {
  desc = "Add Pi comment to current line",
  silent = true,
})
vim.keymap.set("x", "<Plug>(PiAnnotate)", ":<C-U>'<,'>PiAnnotate<CR>", {
  desc = "Add Pi comment to selected lines",
  silent = true,
})
vim.keymap.set("n", "<Plug>(PiSubmit)", "<Cmd>PiSubmit<CR>", {
  desc = "Submit Pi comments",
  silent = true,
})

local defaults_enabled = vim.g.pi_nvim_disable_default_mappings ~= true
  and vim.g.pi_nvim_disable_default_mappings ~= 1

if defaults_enabled then
  if vim.fn.maparg("<leader>pa", "n") == "" and vim.fn.hasmapto("<Plug>(PiAnnotate)", "n") == 0 then
    vim.keymap.set("n", "<leader>pa", "<Plug>(PiAnnotate)", { desc = "Pi annotate line", silent = true })
  end
  if vim.fn.maparg("<leader>pa", "x") == "" and vim.fn.hasmapto("<Plug>(PiAnnotate)", "x") == 0 then
    vim.keymap.set("x", "<leader>pa", "<Plug>(PiAnnotate)", { desc = "Pi annotate selection", silent = true })
  end
  if vim.fn.maparg("<leader>ps", "n") == "" and vim.fn.hasmapto("<Plug>(PiSubmit)", "n") == 0 then
    vim.keymap.set("n", "<leader>ps", "<Plug>(PiSubmit)", { desc = "Pi submit comments", silent = true })
  end
end
