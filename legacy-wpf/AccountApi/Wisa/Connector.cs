using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    static public class Connector
    {
        public static Dictionary<string, string> ReplaceInstNumber = new Dictionary<string, string>();

        private static WISA.TWISAAPICredentials credentials;
        private static WISA.WisaAPIServiceService service;

        internal static ILog Log;

        public static void Init(string url, int port, string accountName, string password, string database, ILog log = null)
        {
            Log = log;

            credentials = new WISA.TWISAAPICredentials
            {
                Username = accountName,
                Password = password,
                Database = database
            };

            service = new WISA.WisaAPIServiceService();
            try
            {
                service.Url = "http://" + url + ":" + port.ToString() + "/SOAP/";
            }
            catch (Exception e)
            {
                Log?.AddError(Origin.Wisa, e.Message);
            }

        }

        static public async Task<string> PerformQuery(string name, WISA.TWISAAPIParamValue[] values)
        {
            return await Task.Run(() =>
            {
                try
                {
                    var data = service.GetCSVData(credentials, name, values, true, ",", "");
                    return Encoding.Default.GetString(data);
                }
                catch (Exception e)
                {
                    Log?.AddError(Origin.Wisa, e.Message);
                    return String.Empty;
                }
            });
        }

        static public void GetClassList(string IDListCSV)
        {
            List<WISA.TWISAAPIParamValue> values = new List<WISA.TWISAAPIParamValue>
            {
                new WISA.TWISAAPIParamValue()
            };
            values.Last().Name = "IS_ID";
            values.Last().Value = IDListCSV;
            values.Add(new WISA.TWISAAPIParamValue());
            values.Last().Name = "Werkdatum";
            values.Last().Value = "22/05/2018";

            try
            {
                var result = service.GetCSVData(credentials, "SMATestQ", values.ToArray(), true, ",", "");
                var str = System.Text.Encoding.Default.GetString(result);
                Debug.Write(str);
            }
            catch (Exception e)
            {
                Debug.WriteLine(e.Message);
            }
        }

        static public async Task<bool> TestConnection()
        {
            try
            {
                string result = await Connector.PerformQuery("SMATestCon", null);
                if (result.Length == 0)
                {
                    Connector.Log?.AddError(Origin.Wisa, "Test Connection should have at least one result");
                    return false;
                }
                else
                {
                    Connector.Log?.AddMessage(Origin.Wisa, "Connection Succeeded");
                    return true;
                }
            }
            catch (Exception e)
            {
                Log?.AddError(Origin.Wisa, e.Message);
                return false;
            }
        }
    }
}
