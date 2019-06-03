using AbstractAccountApi;
using DirectoryApi;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public sealed partial class Data
    {
        public List<ClassGroup> ADGroups => DirectoryApi.ClassGroupManager.All;

        const string adGroupsFile = "directoryGroups.json";
        const string adAccountsFile = "directoryAccounts.json";

        private void loadADConfig(JObject obj)
        {
            adDomain = obj.ContainsKey("domain") ? obj["domain"].ToString() : "";
            adAccounts = obj.ContainsKey("accounts") ? obj["accounts"].ToString() : "";
            adClasses = obj.ContainsKey("classes") ? obj["classes"].ToString() : "";
            adStudents = obj.ContainsKey("students") ? obj["students"].ToString() : "";
            adStaff = obj.ContainsKey("staff") ? obj["staff"].ToString() : "";
            adConnectionTested = obj.ContainsKey("connectionTested") ? obj["connectionTested"].ToObject<ConfigState>() : ConfigState.Failed;
            adUseGrades = obj.ContainsKey("useGrades") ? obj["useGrades"].ToObject<bool>() : false;
            adUseYears = obj.ContainsKey("useYears") ? obj["useYears"].ToObject<bool>() : false;
            if(obj.ContainsKey("grades"))
            {
                var grades = (obj["grades"] as JArray);
                for(int i = 0; i < grades.Count && i < adGrades.Count(); i++)
                {
                    adGrades[i] = grades[i].ToString();
                }
            }
            if (obj.ContainsKey("years"))
            {
                var years = (obj["years"] as JArray);
                for (int i = 0; i < years.Count && i < adYears.Count(); i++)
                {
                    adYears[i] = years[i].ToString();
                }
            }

            updateADGrades();
            updateADYears();
        }

        public JObject saveADConfig()
        {
            JObject result = new JObject();
            result["domain"] = adDomain;
            result["accounts"] = adAccounts;
            result["classes"] = adClasses;
            result["students"] = adStudents;
            result["staff"] = adStaff;
            result["connectionTested"] = adConnectionTested.ToString();
            result["useGrades"] = adUseGrades;
            result["useYears"] = adUseYears;
            result["grades"] = new JArray(adGrades);
            result["years"] = new JArray(adYears);
            return result;
        }

        private void loadADFileContent()
        {
            SetADCredentials();

            var adGroupsLocation = Path.Combine(appFolder, adGroupsFile);
            if(File.Exists(adGroupsLocation))
            {
                string content = File.ReadAllText(adGroupsLocation);
                var newObj = JObject.Parse(content);
                DirectoryApi.ClassGroupManager.FromJson(newObj);
            }

            var adAccountsLocation = Path.Combine(appFolder, adAccountsFile);
            if(File.Exists(adAccountsLocation))
            {
                string content = File.ReadAllText(adAccountsLocation);
                var newObj = JObject.Parse(content);
                DirectoryApi.AccountManager.FromJson(newObj);
            }
        }

        public bool SetADCredentials()
        {
            return DirectoryApi.Connector.Init(adDomain, adAccounts, adClasses, adStudents, adStaff, MainWindow.Instance.Log);
        }

        //public async Task<bool> TestADConnection()
        //{
        //    return true;
        //}

        private string adDomain;
        public string ADDomain
        {
            get => adDomain;
            set
            {
                adDomain = value.Trim();
                ADConnectionTested = ConfigState.Unknown;
            }
        }

        private string adAccounts;
        public string ADAccounts
        {
            get => adAccounts;
            set
            {
                adAccounts = value.Trim();
                ADConnectionTested = ConfigState.Unknown;
            }
        }

        private string adClasses;
        public string ADClasses
        {
            get => adClasses;
            set
            {
                adClasses = value.Trim();
                ADConnectionTested = ConfigState.Unknown;
            }
        }

        private string adStudents;
        public string ADStudents
        {
            get => adStudents;
            set
            {
                adStudents = value.Trim();
                ADConnectionTested = ConfigState.Unknown;
            }
        }

        private string adStaff;
        public string ADStaff
        {
            get => adStaff;
            set
            {
                adStaff = value.Trim();
                ADConnectionTested = ConfigState.Unknown;
            }
        }

        private ConfigState adConnectionTested;
        public ConfigState ADConnectionTested
        {
            get => adConnectionTested;
            set
            {
                adConnectionTested = value;
                ConfigChanged = true;
            }
        }

        private bool adUseGrades;

        public bool ADUseGrades
        {
            get { return adUseGrades; }
            set
            {
                adUseGrades = value;
                updateADGrades();
            }
        }

        private string[] adGrades = new string[3];
        public string ADGrade1 { get => adGrades[0]; set { adGrades[0] = value.Trim(); updateADGrades(); } }
        public string ADGrade2 { get => adGrades[1]; set { adGrades[1] = value.Trim(); updateADGrades(); } }
        public string ADGrade3 { get => adGrades[2]; set { adGrades[2] = value.Trim(); updateADGrades(); } }

        private void updateADGrades()
        {
            var grades = new StringCollection();
            grades.AddRange(adGrades);
            ConfigChanged = true;

            if(ADUseGrades)
            {
                DirectoryApi.Connector.StudentGrade = adGrades;
            } else
            {
                DirectoryApi.Connector.StudentGrade = new string[0];
            }
        }

        private bool adUseYears;

        public bool ADUseYears
        {
            get { return adUseYears; }
            set
            {
                adUseYears = value;
                updateADYears();
            }
        }

        private string[] adYears = new string[7];
        public string ADYear1 { get => adYears[0]; set { adYears[0] = value.Trim(); updateADYears(); } }
        public string ADYear2 { get => adYears[1]; set { adYears[1] = value.Trim(); updateADYears(); } }
        public string ADYear3 { get => adYears[2]; set { adYears[2] = value.Trim(); updateADYears(); } }
        public string ADYear4 { get => adYears[3]; set { adYears[3] = value.Trim(); updateADYears(); } }
        public string ADYear5 { get => adYears[4]; set { adYears[4] = value.Trim(); updateADYears(); } }
        public string ADYear6 { get => adYears[5]; set { adYears[5] = value.Trim(); updateADYears(); } }
        public string ADYear7 { get => adYears[6]; set { adYears[6] = value.Trim(); updateADYears(); } }

        private void updateADYears()
        {
            var years = new StringCollection();
            years.AddRange(adYears);
            ConfigChanged = true;

            if(adUseYears)
            {
                Connector.StudentYear = adYears;
            } else
            {
                Connector.StudentYear = new string[0];
            }
        }

        public async Task ReloadADClassGroups()
        {
            await ClassGroupManager.Load();
            ClassGroupManager.Sort();
            SaveADGroupsToFile();
        }

        public async Task ReloadADAccounts()
        {
            await DirectoryApi.AccountManager.LoadStaff();
            await DirectoryApi.AccountManager.LoadStudents();
            SaveADAccountsToFile();
        }

        public void SaveADGroupsToFile()
        {
            var json = ClassGroupManager.ToJson();
            var location = Path.Combine(appFolder, adGroupsFile);
            File.WriteAllText(location, json.ToString());
        }

        public void SaveADAccountsToFile()
        {
            var json = DirectoryApi.AccountManager.ToJson();
            var location = Path.Combine(appFolder, adAccountsFile);
            File.WriteAllText(location, json.ToString());
        }
    }
}
