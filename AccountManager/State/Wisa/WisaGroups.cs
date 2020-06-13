using AccountApi;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Wisa
{
    public class WisaGroups
    {
        public ObservableCollection<AccountApi.Wisa.ClassGroup> List => AccountApi.Wisa.ClassGroupManager.All;
        DateTime lastSync;
        public DateTime LastSync => lastSync;

        const string fileName = "wisaClasses.json";

        public async Task Load()
        {
            

            // reload list of classes
            AccountApi.Wisa.ClassGroupManager.Clear();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                // check date
                DateTime workDate = DateTime.Now;

                if (school.IsActive)
                {
                    if (App.Instance.Wisa.IsSchoolVirtual(school))
                    {
                        if (!App.Instance.Wisa.WorkDateIsNow.Value)
                        {
                            workDate = App.Instance.Wisa.WorkDate.Value;
                        }
                    }
                    else
                    {
                        if (!App.Instance.Wisa.WorkDateIsNow.Value && !App.Instance.Wisa.WorkDateOnlyVirtual.Value)
                        {
                            workDate = App.Instance.Wisa.WorkDate.Value;
                        }
                    }

                    bool success = await AccountApi.Wisa.ClassGroupManager.AddSchool(school, workDate).ConfigureAwait(false);
                    if (!success) return;
                }
            }
            AccountApi.Wisa.ClassGroupManager.ApplyImportRules(App.Instance.Wisa.ImportRules.ToList());
            AccountApi.Wisa.ClassGroupManager.Sort();
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
                AccountApi.Wisa.ClassGroupManager.FromJson(newObj);
                lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
            }

            App.Instance.Wisa.UpdateObservers();
        }

        public void SaveToJson()
        {
            var json = AccountApi.Wisa.ClassGroupManager.ToJson();
            json["lastSync"] = lastSync;

            var location = Path.Combine(App.GetAppFolder(), fileName);
            File.WriteAllText(location, json.ToString());
        }
    }
}
