using AccountManager.Action.StaffAccount;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Azure
{
    public class AzureGroups
    {
        DateTime lastSync;
        public DateTime LastSync => lastSync;

        const string fileName = "azureGroups.json";

        public async Task Load()
        {
            bool success = await AccountApi.Azure.GroupManager.Instance.LoadFromAzure().ConfigureAwait(false);
            if (success)
            {
                lastSync = DateTime.Now;
                SaveToJson();
            }

            // not ideal to put this here, but it will do for now
            AddToAzureStaffGroup.loadGroups();
            App.Instance.Azure.UpdateObservers();
        }

        public void LoadFromJson()
        {
            var location = Path.Combine(App.GetAppFolder(), fileName);
            if (File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = JObject.Parse(content);
                AccountApi.Azure.GroupManager.Instance.FromJson(newObj);
                lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }
            App.Instance.Azure.UpdateObservers();
        }

        public void SaveToJson()
        {
            var json = AccountApi.Azure.GroupManager.Instance.ToJson();
            json["lastSync"] = LastSync;
            var location = Path.Combine(App.GetAppFolder(), fileName);
            File.WriteAllText(location, json.ToString());
        }
    }
}
