using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State
{
    public sealed class App
    {
        private static readonly App state = new App();
        public static App Instance { get { return state; } }

        Wisa.WisaState wisaState = new State.Wisa.WisaState();
        public Wisa.WisaState Wisa => wisaState;

        AD.ADState adState = new State.AD.ADState();
        public AD.ADState AD => adState;

        Google.GoogleState googleState = new State.Google.GoogleState();
        public Google.GoogleState Google => googleState;

        Smartschool.SmartschoolState smartschoolState = new Smartschool.SmartschoolState();
        public Smartschool.SmartschoolState Smartschool => smartschoolState;

        Settings.SettingsState settingsState = new Settings.SettingsState();
        public Settings.SettingsState Settings => settingsState;

        Linked.LinkedState linkedState = new Linked.LinkedState();
        public Linked.LinkedState Linked => linkedState;

        private App()
        {
            
            
        }

        public void Initialize()
        {
            var configFile = GetConfigFilePath();
            if (File.Exists(configFile))
            {
                LoadConfiguration(configFile);
                loadLocalContent();
            }
        }

        ~App()
        {
            SaveConfiguration(GetConfigFilePath());
            saveLocalContent();
        }

        private void parseConfiguration(JObject config)
        {
            if (config.ContainsKey("Wisa")) Wisa.LoadConfig(config["Wisa"] as JObject);
            if (config.ContainsKey("Smartschool")) Smartschool.LoadConfig(config["Smartschool"] as JObject);
            if (config.ContainsKey("Google")) Google.LoadConfig(config["Google"] as JObject);
            if (config.ContainsKey("AD")) AD.LoadConfig(config["AD"] as JObject);
            if (config.ContainsKey("global")) Settings.LoadConfig(config["global"] as JObject);
        }

        public void LoadConfiguration(string fileName)
        {
            string content = File.ReadAllText(fileName);
            JObject config = JObject.Parse(content);
            parseConfiguration(config);
        }

        public void SaveConfiguration(string fileName)
        {
            JObject config = new JObject();
            config["global"] = Settings.SaveConfig();
            config["Wisa"] = Wisa.SaveConfig();
            config["Smartschool"] = Smartschool.SaveConfig();
            config["Google"] = Google.SaveConfig();
            config["AD"] = AD.SaveConfig();
            File.WriteAllText(fileName, config.ToString());
        }

        private void loadLocalContent()
        {
            Wisa.LoadLocalContent();
            Smartschool.LoadLocalContent();
            Google.LoadLocalContent();
            AD.LoadLocalContent();
        }

        private void saveLocalContent()
        {
            Wisa.SaveContent();
            Smartschool.SaveContent();
            Google.SaveContent();
            AD.SaveContent();
        }

        /// <summary>
        /// Return application folder and create it if it does not exists
        /// </summary>
        /// <returns>string</returns>
        public static string GetAppFolder()
        {
            var folder = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            folder = Path.Combine(folder, "AccountManager");

            if (!Directory.Exists(folder)) Directory.CreateDirectory(folder);

            return folder;
        }

        /// <summary>
        /// Get full path to configuration file. This does not check if the file exists, but
        /// will create the folder if needed.
        /// </summary>
        /// <returns></returns>
        public static string GetConfigFilePath()
        {
            return Path.Combine(GetAppFolder(), "config.json");
        }

    }
}
