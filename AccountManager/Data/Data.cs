using AbstractAccountApi;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        private static readonly Lazy<Data> data = new Lazy<Data>(() => new Data());

        public static Data Instance { get { return data.Value; } }

        string appFolder;
        string configFile;

        public bool ConfigChanged { get; set; }
        public bool ShowDebugInterface { get; set; }

        private bool configReady = false;
        public bool ConfigReady => configReady;

        private Data()
        {
            appFolder = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            appFolder = Path.Combine(appFolder, "AccountManager");
            if (!Directory.Exists(appFolder))
            {
                Directory.CreateDirectory(appFolder);
            }
            configFile = Path.Combine(appFolder, "config.json");

            if(File.Exists(configFile))
            {
                LoadConfig(configFile);
                configReady = true;
            }
        }

        public void LoadConfig(string FileName)
        {
            string content = File.ReadAllText(FileName);
            JObject config = JObject.Parse(content);
            if(config.ContainsKey("global"))
            {
                LoadGlobalConfig(config["global"] as JObject);
            }
            if (config.ContainsKey("Wisa"))
            {
                LoadWisaConfig(config["Wisa"] as JObject);
            }
            if (config.ContainsKey("Smartschool"))
            {
                LoadSmartschoolConfig(config["Smartschool"] as JObject);
            }
            if (config.ContainsKey("Google"))
            {
                LoadGoogleConfig(config["Google"] as JObject);
            }
            if (config.ContainsKey("AD"))
            {
                LoadADConfig(config["AD"] as JObject);
            }
        }

        public void LoadFileContentOnStartup()
        {
            LoadWisaFileContent();
            LoadSmartschoolFileContent();
            LoadGoogleFileContent();
            LoadADFileContent();
            LoadPasswordFileContent();
        }

        public void SaveConfig()
        {
            SaveConfig(configFile);
        }

        public void SaveConfig(string fileName)
        {
            JObject config = new JObject();
            config["global"] = SaveGlobalConfig();
            config["Wisa"] = SaveWisaConfig();
            config["Smartschool"] = SaveSmartschoolConfig();
            config["Google"] = SaveGoogleConfig();
            config["AD"] = SaveADConfig();
            File.WriteAllText(fileName, config.ToString());
            ConfigChanged = false;

            SavePasswordFileContent();
        }

        private JObject SaveGlobalConfig()
        {
            JObject result = new JObject
            {
                ["debugmode"] = ShowDebugInterface,
            };
            return result;
        }

        private void LoadGlobalConfig(JObject obj)
        {
            ShowDebugInterface = obj.ContainsKey("debugmode") ? Convert.ToBoolean(obj["debugmode"]) : false;
        }

        public void SaveContent()
        {
            SaveADAccountsToFile();
            SaveADGroupsToFile();
            SaveSmartschoolAccount();
            SaveGoogleAccountsToFile();
        }
    }
}
