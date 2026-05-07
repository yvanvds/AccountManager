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
    public static class Students
    {
        private static ObservableCollection<Student> all = new ObservableCollection<Student>();
        public static ObservableCollection<Student> All { get => all; }

        public static Student GetByWisaID(string wisaID)
        {
            foreach (var student in all)
            {
                if (student.WisaID.Equals(wisaID)) return student;
            }
            return null;
        }

        public static void Clear()
        {
            all.Clear();
        }

        public static void Sort()
        {
            all = new ObservableCollection<Student>(all.OrderBy(i => i.Name));
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

            string result = await Connector.PerformQuery("SmaSyncLln", values.ToArray());

            if (result.Length == 0)
            {
                Connector.Log?.AddError(Origin.Wisa, "Students: empty result");
                return false;
            }

            int count = 0;
            using (StringReader reader = new StringReader(result))
            {
                string line = reader.ReadLine();
                if (!line.Equals("KLAS,KLASGROEP,NAAM,VOORNAAM,ROEPNAAM,GEBOORTEDATUM,WISAID,STAMBOEKNUMMER,GESLACHT,RIJKSREGISTERNR,GEBOORTEPLAATS,NATIONALITEIT,STRAAT,STRAATNR,BUSNR,POSTCODE,WOONPLAATS,KLASWIJZIGING"))
                {
                    Connector.Log?.AddError(Origin.Wisa, "Error while getting students. Headers do not match: " + line);
                    return false;
                }


                while (true)
                {
                    line = reader.ReadLine();
                    if (line == null) break;

                    try
                    {
                        all.Add(new Student(line, school.ID));
                        count++;
                    }
                    catch (Exception e)
                    {
                        Connector.Log?.AddError(Origin.Wisa, "Parse error (" + e.Message + ") on line " + line);
                        return false;
                    }
                }
            }

            Connector.Log?.AddMessage(Origin.Wisa, "Loading " + count.ToString() + "students from " + school.Name + " succeeded.");
            return true;
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
                all.Add(new Student(account as JObject));
            }
        }
    }
}


/* Query:
 * 
 * SELECT DISTINCT 
	klas.KL_CODE as KLAS,
KLASGROEP.KG_CODE AS KLASGROEP,
	leerling.LL_NAAM as NAAM,
	leerling.LL_VOORNAAM as VOORNAAM,
	leerling.LL_GEBOORTEDATUM as GEBOORTEDATUM,
	leerling.LL_ID AS WISAID,
	inuit.IU_STAMBOEKNUMMER as STAMBOEKNUMMER,
	leerling.LL_GESLACHT as GESLACHT,
	leerling.LL_RIJKSREGISTERNR as RIJKSREGISTERNR,
	GEBOORTEGEMEENTE.GM_DEELGEMEENTE as GEBOORTEPLAATS,
	NATIONALITEIT.NA_OMSCHRIJVING as NATIONALITEIT,
	LEERLINGADRES.LA_STRAAT as STRAAT,
	LEERLINGADRES.LA_STRAATNR as STRAATNR,
	LEERLINGADRES.LA_STRAATBUS as BUSNR,
	ADRESGEMEENTE.GM_POSTNUMMER as POSTCODE,
	ADRESGEMEENTE.GM_DEELGEMEENTE as WOONPLAATS,
	loopbaan.LB_VAN as KLASWIJZIGING
FROM instelling
    INNER JOIN school ON school.SC_ID = instelling.IS_SCHOOL_FK
    INNER JOIN inuit ON inuit.IU_SCHOOL_FK = school.SC_ID
    INNER JOIN leerling ON leerling.LL_ID = inuit.IU_LEERLING_FK
    INNER JOIN loopbaan ON loopbaan.LB_INUIT_FK = inuit.IU_ID
    INNER JOIN klasgroep ON klasgroep.KG_ID = loopbaan.LB_KLASGROEP_FK
    INNER JOIN klas ON klas.KL_ID = klasgroep.KG_KLAS_FK
    INNER JOIN GEMEENTE GEBOORTEGEMEENTE ON leerling.LL_GEBOORTEGEMEENTE_FK = GEBOORTEGEMEENTE.GM_ID
    INNER JOIN NATIONALITEIT ON leerling.LL_NATIONALITEIT_FK = NATIONALITEIT.NA_ID
    INNER JOIN LEERLINGADRES ON LEERLINGADRES.LA_LEERLING_FK = leerling.LL_ID
    INNER JOIN GEMEENTE ADRESGEMEENTE ON LEERLINGADRES.LA_GEMEENTE_FK = ADRESGEMEENTE.GM_ID
    INNER JOIN ADMGROEP ON loopbaan.LB_ADMGROEP_FK = ADMGROEP.AG_ID
WHERE 
	LEERLINGADRES.LA_TYPEADRES_FKP = (SELECT Parmtab.P_ID FROM Parmtab WHERE Parmtab.P_Code = 'O' 
	AND Parmtab.P_Type = 'TPAD') 
	AND instelling.IS_ID = :IS_ID
	AND :werkdatum BETWEEN loopbaan.LB_VAN AND loopbaan.LB_TOT 
	AND :werkdatum BETWEEN inuit.IU_DATUMINSCHRIJVING
	AND inuit.IU_DATUMUITSCHRIJVING 
ORDER BY 
	LL_NAAMSORT, LL_VOORNAAMSORT

  */