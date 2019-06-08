using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    /// <summary>
    /// Smartschool has a table with error messages. When an error occurs, the error code can be converted
    /// to a message using this table. This means the table has to be loaded first (GetCodes). Once loaded,
    /// this class can be used to add message to the log. The log object itself is passed as an argument
    /// when the Init method on the Connector is called.
    /// </summary>
    internal static class Error
    {
        /// <summary>
        /// A json list of all error codes
        /// </summary>
        private static JObject errorCodes;

        /// <summary>
        /// Loads the error codes from smartschool and saves them in the errorCodes object.
        /// When the list with errorCodes is alread loaded, nothing will happen.
        /// </summary>
        internal static void GetCodes()
        {
            if (errorCodes != null) return;

            try
            {
                var result = Connector.service.returnJsonErrorCodes();
                errorCodes = JObject.Parse(result);

            }
            catch (Exception e)
            {
                AddError(e.Message);
            }
        }

        /// <summary>
        /// Convert an error code to its string value.
        /// </summary>
        /// <param name="error">The error code</param>
        /// <returns>A string explanation of the error. Or 'Invalid Error' when the code is not known.</returns>
        internal static string ToString(int error)
        {
            try
            {
                return errorCodes[error.ToString()].ToString();
            }
            catch (Exception e)
            {
                AddError(e.Message);
            }
            return "Invalid Error";
        }

        /// <summary>
        ///  Add an error to the Log object about the provided error code.
        /// </summary>
        /// <param name="error">The error code to add.</param>
        internal static void AddError(int error)
        {
            AddError(ToString(error));
        }

        /// <summary>
        /// Add a string Error message to the Log object.
        /// </summary>
        /// <param name="error">The text to add as error.</param>
        internal static void AddError(string error)
        {
            if (Connector.Log != null)
            {
                Connector.Log.AddError(Origin.Smartschool, error);
            }
        }

        /// <summary>
        /// Add a string message to the Log object.
        /// </summary>
        /// <param name="message">The text to add as message.</param>
        internal static void AddMessage(string message)
        {
            if (Connector.Log != null)
            {
                Connector.Log.AddMessage(Origin.Smartschool, message);
            }
        }
    }
}
