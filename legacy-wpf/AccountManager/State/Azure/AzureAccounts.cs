using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Azure
{
    public class AzureAccounts
    {
        DateTime lastSync;
        public DateTime LastSync => lastSync;

        const string fileName = "azureAccounts.json";

        public async Task Load()
        {
            bool success = await AccountApi.Azure.UserManager.Instance.LoadFromAzure().ConfigureAwait(false);
            if (success)
            {
                lastSync = DateTime.Now;
                SaveToJson();
            }
            

            App.Instance.Azure.UpdateObservers();
        }

        public void LoadFromJson()
        {
            var location = Path.Combine(App.GetAppFolder(), fileName);
            if (File.Exists(location))
            {
                try
                {
                    string content = File.ReadAllText(location);
                    var newObj = JObject.Parse(content);
                    AccountApi.Azure.UserManager.Instance.FromJson(newObj);
                    lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
                }catch (Exception ex)
                {
                    MainWindow.Instance.Log.AddError(AccountApi.Origin.Other, ex.Message);
                }
                
            }
            App.Instance.Azure.UpdateObservers();
        }

        public void SaveToJson()
        {
            var json = AccountApi.Azure.UserManager.Instance.ToJson();
            json["lastSync"] = LastSync;
            var location = Path.Combine(App.GetAppFolder(), fileName);
            File.WriteAllText(location, json.ToString());
        }
    }
}
