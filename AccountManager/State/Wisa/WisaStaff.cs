using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Wisa
{
    public class WisaStaff
    {
        public List<AccountApi.Wisa.Staff> List => AccountApi.Wisa.StaffManager.All;

        DateTime lastSync;
        public DateTime LastSync => lastSync;
        const string fileName = "wisaStaff.json";

        public async Task Load()
        {
            AccountApi.Wisa.StaffManager.Clear();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                if (school.IsActive)
                {
                    var workDate = App.Instance.Wisa.WorkDateIsNow.Value ? DateTime.Now : App.Instance.Wisa.WorkDate.Value;

                    bool success = await AccountApi.Wisa.StaffManager.Add(school).ConfigureAwait(false);
                    if (!success) return;
                }
            }

            List.Sort((a, b) => a.CODE.CompareTo(b.CODE));
            lastSync = DateTime.Now;

            SaveToJson();
            App.Instance.Wisa.UpdateObservers();
        }

        public void LoadFromJson()
        {
            var location = Path.Combine(App.GetAppFolder(), fileName);
            if (File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                AccountApi.Wisa.StaffManager.FromJson(newObj);
                lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
                App.Instance.Wisa.UpdateObservers();
            }
        }

        public void SaveToJson()
        {
            var json = AccountApi.Wisa.StaffManager.ToJson();
            json["lastSync"] = lastSync;

            var location = Path.Combine(App.GetAppFolder(), fileName);
            File.WriteAllText(location, json.ToString());
        }
    }
}
