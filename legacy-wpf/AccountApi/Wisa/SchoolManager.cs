using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    static public class SchoolManager
    {
        private static ObservableCollection<School> all = new ObservableCollection<School>();
        public static ObservableCollection<School> All { get => all; }

        public static School Get(int ID)
        {
            foreach (var school in all)
            {
                if (school.ID == ID) return school;
            }
            return null;
        }

        public static string ActiveSchoolsToString()
        {
            string result = "";
            foreach (var school in all)
            {
                if (school.IsActive)
                {
                    if (result.Length > 0) result += ",";
                    result += school.ID.ToString();
                }
            }
            return result;
        }

        public static bool ActiveSchoolsFromString(string s)
        {
            string[] list = s.Split(',');
            foreach (var l in list)
            {
                try
                {
                    int ID = Convert.ToInt32(l);
                    School school = Get(ID);
                    if (school != null) school.IsActive = true;
                }
                catch (Exception e)
                {
                    Connector.Log?.AddError(Origin.Wisa, "Invalid list of school ID's (" + e.Message + ")");
                    return false;
                }
            }

            return true;
        }



        public static void Clear()
        {
            all.Clear();
        }


        public static async Task<bool> Load()
        {
            all.Clear();

            string result = await Connector.PerformQuery("SMAGetInst", null);

            if (result.Length == 0)
            {
                Connector.Log?.AddError(Origin.Wisa, "Instellingen: empty result");
                return false;
            }

            using (StringReader reader = new StringReader(result))
            {
                string line = reader.ReadLine();
                // first line contains headers, make sure they are ok
                if (!line.Equals("ID,NAME,DESCRIPTION"))
                {
                    Connector.Log?.AddError(Origin.Wisa, "Error while getting schools. Headers do not match.");
                    return false;
                }

                while (true)
                {
                    line = reader.ReadLine();
                    if (line == null)
                    {
                        break;
                    }

                    string[] values = line.Split(',');
                    try
                    {
                        All.Add(new School(Convert.ToInt32(values[0]), values[2], values[1]));
                    }
                    catch (Exception)
                    {

                    }

                }

                Connector.Log?.AddMessage(Origin.Wisa, "School import succeeded");
                return true;
            }
        }

        public static JObject ToJson()
        {
            JObject result = new JObject();
            var schools = new JArray();
            foreach (var school in All)
            {
                schools.Add(school.ToJson());
            }
            result["Schools"] = schools;
            return result;
        }

        public static void FromJson(JObject obj)
        {
            all.Clear();
            var schools = obj["Schools"].ToArray();
            foreach (var school in schools)
            {
                all.Add(new School(school as JObject));
            }
        }
    }
}
