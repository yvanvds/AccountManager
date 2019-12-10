using AccountApi;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Smartschool
{
    public class SmartschoolGroups
    {
        DateTime lastSync;
        public DateTime LastSync => lastSync;

        const string fileName = "smartschoolGroups.json";

        public async Task Load()
        {
            await AccountApi.Smartschool.GroupManager.Reload();
            AccountApi.Smartschool.GroupManager.Root.ApplyImportRules(App.Instance.Smartschool.ImportRules.ToList());

            // load students accounts
            IGroup students = AccountApi.Smartschool.GroupManager.Root.Find("Leerlingen");
            if (students != null)
            {
                List<IGroup> groups = new List<IGroup>();
                students.GetTreeAsList(groups);

                foreach (var group in groups)
                {
                    await group.LoadAccounts();
                }
            }

            // load staff accounts
            IGroup staff = AccountApi.Smartschool.GroupManager.Root.Find("Personeel");
            if (staff != null)
            {
                List<IGroup> groups = new List<IGroup>();
                staff.GetTreeAsList(groups);

                foreach (var group in groups)
                {
                    await group.LoadAccounts();
                }
            }
            AccountApi.Smartschool.GroupManager.Root.Sort();
            lastSync = DateTime.Now;

            SaveToJson();
        }

        public void LoadFromJson()
        {
            var location = Path.Combine(App.GetAppFolder(), fileName);
            if (File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = JObject.Parse(content);
                AccountApi.Smartschool.GroupManager.FromJson(newObj);
                lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }
        }

        public void SaveToJson()
        {
            var json = AccountApi.Smartschool.GroupManager.ToJson(true);
            if (json != null)
            {
                json["lastSync"] = lastSync;

                var location = Path.Combine(App.GetAppFolder(), fileName);
                File.WriteAllText(location, json.ToString());
            }
        }
    }
}
