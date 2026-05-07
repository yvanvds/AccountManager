using AccountManager.Utils;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Settings
{
    public class SettingsState : AbstractState
    {
        public ConfigValue<bool> DebugMode;
        public ConfigValue<string> SchoolPrefix;

        public SettingsState()
        {
            DebugMode = new ConfigValue<bool>("debugmode", false, UpdateObservers);
            SchoolPrefix = new ConfigValue<string>("schoolprefix", "", UpdateObservers);
        }
        public override void LoadConfig(JObject obj)
        {
            DebugMode.Load(obj);
            SchoolPrefix.Load(obj);
        }

        public override Task LoadContent()
        {
            // no content
            return null;
        }

        public override void LoadLocalContent()
        {
            // no content
        }

        public override JObject SaveConfig()
        {
            JObject result = new JObject();
            DebugMode.Save(ref result);
            SchoolPrefix.Save(ref result);
            return result;
        }

        public override void SaveContent()
        {
            // no content
        }
    }
}
