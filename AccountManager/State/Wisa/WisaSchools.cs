using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Wisa
{
    public class WisaSchools
    {
        public ObservableCollection<AccountApi.Wisa.School> List => AccountApi.Wisa.SchoolManager.All;
        const string fileName = "wisaSchools.json";

        public async Task Load()
        {
            // remember which schools are selected
            List<int> selected = new List<int>();
            foreach (var school in AccountApi.Wisa.SchoolManager.All)
            {
                if (school.IsActive) selected.Add(school.ID);
            }

            // reload list of schools
            bool result = await AccountApi.Wisa.SchoolManager.Load();

            // only save changes if the request succeeded
            if (result)
            {
                // set to selected if the previous had them selected
                foreach (var school in AccountApi.Wisa.SchoolManager.All)
                {
                    if (selected.Contains(school.ID))
                    {
                        school.IsActive = true;
                    }
                }
                // save to disk
                SaveToJson();
            }
            App.Instance.Wisa.UpdateObservers();
        }

        public void LoadFromJson()
        {
            var location = Path.Combine(App.GetAppFolder(), fileName);
            if (File.Exists(location))
            {
                string content = File.ReadAllText(location);
                var newObj = Newtonsoft.Json.Linq.JObject.Parse(content);
                AccountApi.Wisa.SchoolManager.FromJson(newObj);
                App.Instance.Wisa.UpdateObservers();
            }
        }

        public void SaveToJson()
        {
            var json = AccountApi.Wisa.SchoolManager.ToJson();
            var location = Path.Combine(App.GetAppFolder(), fileName);
            File.WriteAllText(location, json.ToString());
        }
    }
}
