using AccountApi.SS;
using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    public static class ClassGroupManager
    {
        private static ObservableCollection<ClassGroup> all = new ObservableCollection<ClassGroup>();
        public static ObservableCollection<ClassGroup> All { get => all; set => all = value; }

        public static void Clear()
        {
            all.Clear();
        }

        public static void Sort()
        {
            all = new ObservableCollection<ClassGroup>(all.OrderBy(i => i.Name));
        }

        public static async Task<bool> AddSchool(School school, DateTime? workdate = null)
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

            string result = await Connector.PerformQuery("SyncKlas", values.ToArray());

            if (result.Length == 0)
            {
                Connector.Log?.AddError(Origin.Wisa, "ClassGroups: empty result");
                return false;
            }

            using (StringReader reader = new StringReader(result))
            {
                string line = reader.ReadLine();
                if (!line.Equals("KLAS,KLASGROEP,OMSCHRIJVING,ADMINGROEP,INSTELLINGSNUMMER"))
                {
                    Connector.Log?.AddError(Origin.Wisa, "Error while getting Classgroups. Headers do not match.");
                    return false;
                }

                while (true)
                {
                    line = reader.ReadLine();
                    if (line == null) break;

                    try
                    {
                        all.Add(new ClassGroup(line, school.ID));
                    }
                    catch (Exception e)
                    {
                        Connector.Log?.AddError(Origin.Wisa, "Parse error (" + e.Message + ") on line " + line);
                        return false;
                    }
                }
            }

            // remove doubles
            var doubles = new List<ClassGroup>();

            foreach(var group in all)
            {
                if (group.GroupName == "00" && UseSubGroups(group))
                {
                    doubles.Add(group);
                } else if (group.GroupName != "00" && !UseSubGroups(group))
                {
                    doubles.Add(group);
                }
            }

            foreach(var group in doubles)
            {
                all.Remove(group);
            }

            Connector.Log?.AddMessage(Origin.Wisa, "Loading classgroups from " + school.Name + " succeeded.");
            return true;
        }

        static ClassGroup GetFirstClass(ClassGroup original)
        {
            foreach(var group in all)
            {
                if (group.Name == original.Name && group.GroupName == "00")
                {
                    return group;
                }
            }
            return null;
        } 

        static int CountGroups(string name)
        {
            int result = 0;
            foreach(var group in all)
            {
                if (group.Name == name && group.GroupName != "00") result++;
            }
            return result;
        }

        static bool UseSubGroups(ClassGroup group)
        {
            List<string> admincodes = new List<string>();
            foreach(var item in all)
            {
                if (item.Name.Equals(group.Name))
                {
                    if (!admincodes.Contains(item.AdminCode))
                    {
                        admincodes.Add(item.AdminCode);
                    }
                }
            }

            return (admincodes.Count > 1);
        }

        public static bool UseSubGroups(string className)
        {
            List<string> admincodes = new List<string>();
            foreach (var item in all)
            {
                if (item.Name.Equals(className))
                {
                    if (!admincodes.Contains(item.AdminCode))
                    {
                        admincodes.Add(item.AdminCode);
                    }
                }
            }

            return (admincodes.Count > 1);
        }


        public static JObject ToJson()
        {
            JObject result = new JObject();
            var groups = new JArray();
            foreach (var group in All)
            {
                groups.Add(group.ToJson());
            }
            result["Groups"] = groups;
            return result;
        }

        public static void FromJson(JObject obj)
        {
            all.Clear();
            var groups = obj["Groups"].ToArray();
            foreach (var group in groups)
            {
                all.Add(new ClassGroup(group as JObject));
            }
        }

        public static void ApplyImportRules(List<IRule> rules)
        {
            for (int group = all.Count - 1; group >= 0; group--)
            {
                for (int i = 0; i < rules.Count; i++)
                {
                    if (rules[i].ShouldApply(all[group]))
                    {
                        if (rules[i].RuleAction == RuleAction.Modify) rules[i].Modify(all[group]);
                        else if (rules[i].RuleAction == RuleAction.Discard)
                        {
                            all.RemoveAt(group);
                            break;
                        }
                    }
                }
            }
        }
    }
}


/* Query:
 * 
 * SELECT KLAS.KL_CODE AS KLAS,
  KLAS.KL_OMSCHRIJVING AS OMSCHRIJVING,
  ADMGROEP.AG_CODE AS ADMINGROEP,
  SCHOOL.SC_INSTELLINGSNUMMER
FROM KLAS
  LEFT JOIN SCHOOLJAAR ON KLAS.KL_SCHOOLJAAR_FK = SCHOOLJAAR.SJ_ID
  LEFT JOIN KLASGROEP ON KLAS.KL_ID = KLASGROEP.KG_KLAS_FK
  LEFT JOIN VAKKENPAKKET ON KLASGROEP.KG_VAKKENPAKKET_FK = VAKKENPAKKET.VK_ID
  LEFT JOIN PARMTAB ON VAKKENPAKKET.VK_LEERJAAR_FKP = PARMTAB.P_ID
  LEFT JOIN ADMGROEP ON VAKKENPAKKET.VK_ADMGROEP_FK = ADMGROEP.AG_ID
  INNER JOIN INSTELLING ON VAKKENPAKKET.VK_INSTELLING_FK = INSTELLING.IS_ID
  INNER JOIN SCHOOL ON INSTELLING.IS_SCHOOL_FK = SCHOOL.SC_ID
WHERE KLAS.KL_INSTELLING_FK = :IS_ID AND :Werkdatum BETWEEN SCHOOLJAAR.SJ_GELDIGVAN AND SCHOOLJAAR.SJ_GELDIGEXT AND
  KLASGROEP.KG_CODE = '00'

  */
