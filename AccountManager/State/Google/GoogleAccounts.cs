using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

//namespace AccountManager.State.Google
//{
//    public class GoogleAccounts
//    {
//        DateTime lastSync;
//        public DateTime LastSync => lastSync;

//        const string fileName = "googleAccounts.json";

//        public async Task Load()
//        {
//            AccountApi.Google.AccountManager.ClearAll();
//            await AccountApi.Google.AccountManager.ReloadAll();
//            lastSync = DateTime.Now;
//            SaveToJson();

//            App.Instance.Google.UpdateObservers();
//        }

//        public void LoadFromJson()
//        {
//            var location = Path.Combine(App.GetAppFolder(), fileName);
//            if (File.Exists(location))
//            {
//                string content = File.ReadAllText(location);
//                var newObj = JObject.Parse(content);
//                AccountApi.Google.AccountManager.FromJson(newObj);
//                lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
//            }
//            App.Instance.Google.UpdateObservers();
//        }

//        public void SaveToJson()
//        {
//            var json = AccountApi.Google.AccountManager.ToJson();
//            json["lastSync"] = LastSync;
//            var location = Path.Combine(App.GetAppFolder(), fileName);
//            File.WriteAllText(location, json.ToString());
//        }
//    }
//}
