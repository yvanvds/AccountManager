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
                string content = File.ReadAllText(configFile);
                JObject config = JObject.Parse(content);
                if(config.ContainsKey("Wisa"))
                {
                    loadWisaConfig(config["Wisa"] as JObject);
                }
                if(config.ContainsKey("Smartschool"))
                {
                    loadSmartschoolConfig(config["Smartschool"] as JObject);
                }
                if(config.ContainsKey("Google"))
                {
                    loadGoogleConfig(config["Google"] as JObject);
                }
                if(config.ContainsKey("AD"))
                {
                    loadADConfig(config["AD"] as JObject);
                }
            }
        }

        public void LoadFileContentOnStartup()
        {
            loadWisaFileContent();
            loadSmartschoolFileContent();
            loadGoogleFileContent();
        }

        public void SaveConfig()
        {
            JObject config = new JObject();
            config["Wisa"] = saveWisaConfig();
            config["Smartschool"] = saveSmartschoolConfig();
            config["Google"] = saveGoogleConfig();
            config["AD"] = saveADConfig();
            File.WriteAllText(configFile, config.ToString());
            ConfigChanged = false;
        }
    }
}
