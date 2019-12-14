using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    public static class StaffManager
    {
        private static List<Staff> all = new List<Staff>();
        public static List<Staff> All { get => all; }

        public static void Clear()
        {
            all.Clear();
        }

        public static async Task<bool> Add(School school, DateTime? workdate = null)
        {
            List<WISA.TWISAAPIParamValue> values = new List<WISA.TWISAAPIParamValue>
            {
                new WISA.TWISAAPIParamValue()
            };
            values.Last().Name = "IS_ID";
            values.Last().Value = school.ID.ToString();

            values.Add(new WISA.TWISAAPIParamValue());
            values.Last().Name = "Werkdatum";
            DateTime date;
            if (!workdate.HasValue)
            {
                date = DateTime.Now;
            }
            else
            {
                date = workdate.Value;
            }
            values.Last().Value = date.ToString("dd/MM/yyyy", new System.Globalization.CultureInfo(String.Empty, false));

            string result = await Connector.PerformQuery("SmaSyncPer", values.ToArray());

            if (result.Length == 0)
            {
                Connector.Log?.AddError(Origin.Wisa, "Staff: empty result");
                return false;
            }

            int count = 0;
            using (StringReader reader = new StringReader(result))
            {
                string line = reader.ReadLine();
                if (!line.Equals("CODE,FAMILIENAAM,VOORNAAM"))
                {
                    Connector.Log?.AddError(Origin.Wisa, "Error while getting staff. Headers do not match.");
                    return false;
                }

                while (true)
                {
                    line = reader.ReadLine();
                    if (line == null) break;

                    try
                    {
                        var staff = new Staff(line);

                        if(!exists(staff))
                        {
                            all.Add(staff);
                            count++;
                        }
                        
                    }
                    catch (Exception e)
                    {
                        Connector.Log?.AddError(Origin.Wisa, "Parse error (" + e.Message + ") on line " + line);
                        return false;
                    }
                }
            }

            Connector.Log?.AddMessage(Origin.Wisa, "Loading " + count.ToString() + " staff members from " + school.Name + " succeeded.");
            return true;
        }

        private static bool exists(Staff staff)
        {
            foreach(var s in all)
            {
                if (s.CODE.Equals(staff.CODE)) return true;
            }
            return false;
        }

        public static JObject ToJson()
        {
            JObject result = new JObject();
            var accounts = new JArray();
            foreach (var account in All)
            {
                accounts.Add(account.ToJson());
            }
            result["Accounts"] = accounts;
            return result;
        }

        public static void FromJson(JObject obj)
        {
            all.Clear();
            var accounts = obj["Accounts"].ToArray();
            foreach (var account in accounts)
            {
                all.Add(new Staff(account as JObject));
            }
        }

        public static void ApplyImportRules(List<IRule> rules)
        {
            for(int account = all.Count -1; account >= 0; account--)
            {
                for(int i = 0; i < rules.Count; i++)
                {
                    if (rules[i].Rule == Rule.WI_DontImportUser)
                    {
                        if (rules[i].ShouldApply(all[account]))
                        {
                            all.RemoveAt(account);
                            break;
                        }
                    }
                }
            }
        }
    }
}
