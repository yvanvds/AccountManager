using AccountApi;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Data;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Wisa
{
    public class WisaStudents
    {
        public ObservableCollection<AccountApi.Wisa.Student> List => AccountApi.Wisa.Students.All;
        DateTime lastSync;
        public DateTime LastSync => lastSync;

        const string fileName = "wisaStudents.json";

        public async Task Load()
        {
            AccountApi.Wisa.Students.Clear();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                if (school.IsActive)
                {
                    var workDate = DateTime.Now;
                    if (App.Instance.Wisa.IsSchoolVirtual(school))
                    {
                        if (!App.Instance.Wisa.WorkDateVirtualIsNow.Value)
                        {
                            workDate = App.Instance.Wisa.WorkDateVirtual.Value;
                        }
                    } else
                    {
                        if (!App.Instance.Wisa.WorkDateIsNow.Value)
                        {
                            workDate = App.Instance.Wisa.WorkDate.Value;
                        }
                    }

                    bool success = await AccountApi.Wisa.Students.AddSchool(school, workDate).ConfigureAwait(false);
                    if (!success) return;
                }
            }

            // remove students in discarded classgroups from this list
            for (int i = List.Count - 1; i >= 0; i--)
            {
                foreach (var rule in App.Instance.Wisa.ImportRules)
                {
                    if (rule.Rule == AccountApi.Rule.WI_DontImportClass && rule.GetConfig(0) == AccountApi.Wisa.Students.All[i].ClassGroup)
                    {
                        AccountApi.Wisa.Students.All.RemoveAt(i);
                        break;
                    }
                }
            }

            AccountApi.Wisa.Students.Sort();
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
                AccountApi.Wisa.Students.FromJson(newObj);
                lastSync = newObj.ContainsKey("lastSync") ? Convert.ToDateTime(newObj["lastSync"]) : DateTime.MinValue;
                App.Instance.Wisa.UpdateObservers();
            }
        }

        public void SaveToJson()
        {
            var json = AccountApi.Wisa.Students.ToJson();
            json["lastSync"] = lastSync;

            var location = Path.Combine(App.GetAppFolder(), fileName);
            File.WriteAllText(location, json.ToString());
        }
    }
}
