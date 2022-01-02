local M = {}

local uv = vim.loop
local packer = require "packer"
local utils = require "lvim.utils"
local a = require "packer.async"
local async = a.sync
local await = a.wait
local wrap = a.wrap
local jobs = require "packer.jobs"
local result = require "packer.result"
local async_stat = wrap(uv.fs_stat)

local path_sep = uv.os_uname().version:match "Windows" and "\\" or "/"

local timer = {}
function timer:start()
  self.time = uv.hrtime()
end
function timer:stop()
  return (uv.hrtime() - self.time) * 1e-6
end

local function mkdir_tmp()
  local tmpFilePath = os.tmpname()
  vim.fn.delete(tmpFilePath)

  local sep_idx = tmpFilePath:reverse():find(path_sep)
  local path = tmpFilePath:sub(1, #tmpFilePath - sep_idx)
  uv.fs_mkdtemp(path .. path_sep .. "lvim_core_dl_XXXXXX")
  return path
end

local function get_lvim_after_user_config()
  local original_lvim = lvim
  local user_lvim = vim.deepcopy(lvim)
  local original_package_loaded = package.loaded
  local user_package_loaded = {}
  _G.lvim = user_lvim
  _G.package.loaded = user_package_loaded
  local ok, err = pcall(dofile, require("lvim.config"):get_user_config_path())
  if not ok then
    print(err)
  end
  _G.lvim = original_lvim
  _G.package.loaded = original_package_loaded

  return user_lvim
end

---downloads and installs from a core plugin entry
---@param plug table plugin entry
---@return function
local function download_and_install(plug, core_install_dir, download_dir)
  local commit = plug.commit
  local repo = plug[1]
  local name = repo:match "/(%S*)"
  local zip_name = commit .. ".zip"
  local extracted_dir = join_paths(core_install_dir, name .. "-" .. commit)

  return async(function()
    if not plug.commit then
      error("commit missing for plugin: " .. repo)
    end
    local _, dir_exists = await(async_stat(extracted_dir))
    local r = result.ok()
    -- skip plugins that are already installed
    if dir_exists then
      return r
    end

    local url = "https://github.com/" .. repo .. "/archive/" .. zip_name

    return r
      :and_then(await, jobs.run({ "curl", "-LO", url }, { cwd = download_dir }))
      :and_then(await, jobs.run({ "unzip", "-o", join_paths(download_dir, zip_name), "-d", core_install_dir }, {}))
      :or_else(function()
        error("download and install failed for plugin '" .. repo .. "'")
      end)
  end)
end

function M.init(opts)
  local core_install_dir = opts.core_install_dir or vim.fn.stdpath "data" .. "/core"
  assert(vim.fn.executable "curl", "curl is not installed")
  assert(vim.fn.executable "unzip", "unzip is not installed")

  if not utils.is_directory(core_install_dir) then
    assert(vim.fn.mkdir(core_install_dir), "unable to create core plugin install directory")
  end

  local download_dir = mkdir_tmp()
  assert(download_dir, "unable to create core plugin download directory")

  local core_plugins = require "lvim.plugins"

  -- prevent packer from loading plugins on run hooks
  local load_plugin = require("packer.plugin_utils").load_plugin
  require("packer.plugin_utils").load_plugin = function() end
  print "Downloading core plugins..."

  local packer_stage = 0

  async(function()
    timer:start()
    local tasks = {}
    for _, plug in ipairs(core_plugins) do
      table.insert(tasks, download_and_install(plug, core_install_dir, download_dir))
    end
    a.wait_all(unpack(tasks))
    await(a.main)

    print("Downloaded core plugins in:", timer:stop(), "ms")
    vim.fn.delete(download_dir, "rf")
    vim.fn.delete(download_dir, "d")
    if opts.packer_cache_path then
      vim.fn.delete(opts.packer_cache_path)
    end
    if opts.lua_cache_path then
      vim.fn.delete(opts.lua_cache_path)
    end

    local plugin_loader = require "lvim.plugin-loader"
    plugin_loader.load { core_plugins }

    packer.on_complete = function() end
    packer.on_compile_done = function()
      if packer_stage == 0 then
        print("Installed core plugins in:", timer:stop(), "ms")
        packer_stage = 1

        timer:start()
        print "Loading core plugins..."
        packer.compile()
      elseif packer_stage == 1 then
        for _, core_plugin in pairs(core_plugins) do
          pcall(load_plugin, core_plugin)
        end
        print("Loaded core plugins in:", timer:stop(), "ms")
        packer_stage = 2

        require("lvim.config"):init()
        local user_lvim = get_lvim_after_user_config()
        print "Installing user plugins..."
        timer:start()

        for _, entry in ipairs(user_lvim.plugins) do
          print("-", entry[1])
        end

        packer.on_complete = packer.on_compile_done
        require("lvim.plugin-loader").load { core_plugins, user_lvim.plugins }
        packer.install()
      elseif packer_stage == 2 then
        packer_stage = 3
        packer.compile()
      elseif packer_stage == 3 then
        print("Installed user plugins in:", timer:stop(), "ms")
        vim.cmd [[qall!]]
      end
    end

    timer:start()
    print "Installing core plugins..."
    packer.sync()
  end)()
end

return M
