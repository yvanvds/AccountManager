using System;

namespace AzureApi
{
    public sealed class Connector
    {
        private static readonly Connector connector = new Connector();
        public static Connector Instance { get { return connector; } }
        private Connector() { }

        public void Connect()
        {

        }
    }
}
